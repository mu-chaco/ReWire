{-# LANGUAGE FlexibleContexts, LambdaCase, ScopedTypeVariables, GADTs, TupleSections #-}
{-# LANGUAGE Safe #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
module ReWire.FrontEnd.Transform
      ( inline, reduce
      , neuterPrims
      , shiftLambdas
      , liftLambdas
      , purgeUnused
      ) where

import ReWire.Error
import ReWire.FrontEnd.Syntax
import ReWire.FrontEnd.Unbound
      ( Fresh (..), s2n, n2s
      , substs, subst, unembed
      , isFreeName, runFreshM, runFreshMT
      , Name (..)
      )
import ReWire.SYB

import Control.Arrow (first)
import Control.Monad.Catch (MonadCatch)
import Control.Monad.State (State, evalStateT, execState, StateT (..), get, modify)
import Control.Monad (replicateM)
import Data.Data (Data)
import Data.List (nub, find, foldl')
import Data.Maybe (fromJust, fromMaybe)

import Data.Set (Set, union, (\\))
import qualified Data.Set as Set

-- | Inlines defs marked for inlining. Must run before lambda lifting.
inline :: FreeProgram -> FreeProgram
inline (ts, ds) = (ts, substs subs ds)
      where toSubst :: Defn -> (Name Exp, Exp)
            toSubst (Defn _ n _ _ (Embed e)) = runFreshM $ do
                  (_, e') <- unbind e
                  pure (n, e')
            subs = map toSubst $ substs (map toSubst $ filter defnInline ds) $ filter defnInline ds

-- | Replaces the expression in NativeVHDL so we don't descend into it
--   during other transformations.
neuterPrims :: MonadCatch m => FreeProgram -> m FreeProgram
neuterPrims = runT $ transform $
      \ (NativeVHDL an s e) -> pure $ NativeVHDL an s (Error an (typeOf e) "nativeVHDL expression placeholder")

shiftLambdas :: FreeProgram -> FreeProgram
shiftLambdas (ts, vs) = (ts, map shiftLambdas' vs)
      where shiftLambdas' :: Defn -> Defn
            shiftLambdas' (Defn an n t inl (Embed e)) = Defn an n t inl (Embed $ mash e)

            mash :: Bind [Name Exp] Exp -> Bind [Name Exp] Exp
            mash e = runFreshM $ do
                  (vs, e') <- unbind e
                  case e' of
                        Lam _ _ b -> do
                              (v, b') <- unbind b
                              pure $ mash $ bind (vs ++ [v]) b'
                        _ -> pure e

-- | This is a hacky SYB-based lambda lifter, it requires some ugly mucking
--   with the internals of unbound-generics.
liftLambdas :: MonadCatch m => FreeProgram -> m FreeProgram
liftLambdas p = runFreshMT $ evalStateT (runT liftLambdas' p) []
      where liftLambdas' :: (MonadCatch m, Fresh m) => Transform (StateT [Defn] m)
            liftLambdas' =  \ case
                  Lam an t b -> do
                        (x, e)    <- unbind b
                        -- The only free names should be globally-bound
                        -- variables (and x) at this point and we can also
                        -- assume every bound name in e' was bound at a level above e'.
                        let bvs   = bv e
                        (fvs, e') <- freshen e

                        let t' = foldr arr (typeOf e') $ map snd bvs ++ [t]
                        f     <- fresh $ s2n "$LL.lambda"

                        modify $ (:) $ Defn an f (fv t' |-> t') False (Embed $ bind (fvs ++ [x]) e')
                        pure $ foldl' (\ e' (v, vt) -> App an e' $ Var an vt v) (Var an t' f) $ map (first promote) bvs
                  Case an t e1 b e2 -> do
                        (p, e)    <- unbind b
                        let bvs   = bv e
                        (fvs, e') <- freshen e

                        let pvs = patVars p

                        let t' = foldr arr (typeOf e) $ map snd bvs ++ map snd pvs
                        f     <- fresh $ s2n "$LL.case"

                        modify $ (:) $ Defn an f (fv t' |-> t') False (Embed $ bind (fvs ++ map fst pvs) e')
                        pure $ Match an t e1 (transPat p) (Var an t' f) (map (\ (v, vt) -> Var an vt (promote v)) bvs) e2
                  -- TODO(chathhorn): This case is really just normalizing
                  -- Match, consider moving to ToCore.
                  Match an t e1 p e lvars els -> do
                        let bvs   = bv e
                        (fvs, e') <- freshen e

                        let t' = foldr (arr . snd) (typeOf e) bvs
                        f     <- fresh $ s2n "$LL.match"

                        modify $ (:) $ Defn an f (fv t' |-> t') False (Embed $ bind fvs e')
                        pure $ Match an t e1 p (Var an t' f) (map (\ (v, vt) -> Var an vt v) bvs ++ lvars) els
                  ||> (\ ([] :: [Defn]) -> get) -- this is cute!
                  ||> TId

            freshen :: (MonadCatch m, Fresh m) => Exp -> m ([Name Exp], Exp)
            freshen e = do
                  let bvs  = bv e
                  fvs      <- replicateM (length bvs) $ fresh $ s2n "$LL"
                  e'       <- substs' (zip (map fst bvs) fvs) e
                  pure (fvs, e')

            substs' :: MonadCatch m => [(Name Exp, Name Exp)] -> Exp -> m Exp
            substs' subs = runT (transform $ \ n -> pure $ fromMaybe n (lookup n subs))

            bv :: Data a => a -> [(Name Exp, Ty)]
            bv = nub . runQ (query $ \ case
                  Var _ t n | not $ isFreeName n -> [(n, t)]
                  _                              -> [])

            patVars :: Pat -> [(Name Exp, Ty)]
            patVars = \ case
                  PatCon _ _ _ ps      -> concatMap patVars ps
                  PatVar _ (Embed t) x -> [(x, t)]

            promote :: Name a -> Name a
            promote (Bn l k) | l >= 0 = Bn (l - 1) k
            promote b = b

            transPat :: Pat -> MatchPat
            transPat = \ case
                  PatCon an (Embed t) (Embed c) ps -> MatchPatCon an t c $ map transPat ps
                  PatVar an (Embed t) _            -> MatchPatVar an t

-- | Remove unused definitions.
purgeUnused :: FreeProgram -> FreeProgram
purgeUnused (ts, vs) = (inuseData (fv $ trec $ inuseDefn vs) ts, inuseDefn vs)
      where inuseData :: [Name DataConId] -> [DataDefn] -> [DataDefn]
            inuseData ns = map $ inuseData' ns

            inuseData' :: [Name DataConId] -> DataDefn -> DataDefn
            inuseData' ns d@(DataDefn an n k cs)
                  | n2s n `elem` reservedData = d
                  | otherwise                 = DataDefn an n k $ filter ((`Set.member` Set.fromList ns) . dataConName) cs

            reservedData :: [String]
            reservedData =
                         [ "Prelude.Either"
                         , "(,)"
                         , "()"
                         ]

            dataConName :: DataCon -> Name DataConId
            dataConName (DataCon _ n _) = n

inuseDefn :: [Defn] -> [Defn]
inuseDefn ds = map toDefn $ Set.elems $ execState (inuseDefn' ds') ds'
      where inuseDefn' :: Set (Name Exp) -> State (Set (Name Exp)) ()
            inuseDefn' ns | Set.null ns = pure ()
                          | otherwise   = do
                  inuse  <- get
                  modify $ union (fvs ns)
                  inuse' <- get
                  inuseDefn' $ inuse' \\ inuse

            reservedDefn :: [String]
            reservedDefn =
                         [ "Main.start"
                         , "unfold"
                         ]

            ds' :: Set (Name Exp)
            ds' = Set.fromList $ filter (flip elem reservedDefn . n2s) $ map defnName ds

            fvs :: Set (Name Exp) -> Set (Name Exp)
            fvs = Set.fromList . concatMap (fv . unembed . defnBody . toDefn) . Set.elems

            toDefn :: Name Exp -> Defn
            toDefn n = fromJust $ find ((==n) . defnName) ds

-- | Partially evaluate expressions.
reduce :: MonadError AstError m => FreeProgram -> m FreeProgram
reduce (ts, vs) = (ts, ) <$> mapM reduceDefn vs

reduceDefn :: MonadError AstError m => Defn -> m Defn
reduceDefn (Defn an n pt b (Embed e)) = runFreshMT $ do
      (vs, e') <- unbind e
      (Defn an n pt b . Embed) . bind vs <$> reduceExp e'

reduceExp :: (Fresh m, MonadError AstError m) => Exp -> m Exp
reduceExp = \ case
      App an e1 e2      -> do
            e1' <- reduceExp e1
            e2' <- reduceExp e2
            case e1' of
                  Lam _ _ e -> do
                        (x, e') <- unbind e
                        reduceExp $ subst x e2' e'
                  _              -> pure $ App an e1' e2'
      Lam an t e      -> do
            (x, e') <- unbind e
            Lam an t . bind x <$> reduceExp e'
      Case an t e e1 e2 -> do
            (p, e1') <- unbind e1
            e' <- reduceExp e
            let mr = matchPat e' p
            case mr of
                  MatchYes sub -> reduceExp $ substs sub e1'
                  MatchMaybe   -> case e2 of
                        Nothing  -> Case an t e' <$> (bind p <$> reduceExp e1') <*> pure Nothing
                        Just e2' -> Case an t e' <$> (bind p <$> reduceExp e1') <*> (Just <$> reduceExp e2')
                  MatchNo      -> case e2 of
                        Nothing  -> pure $ Error an t "Pattern match failure (reduced)"
                        Just e2' -> reduceExp e2'
      e -> pure e

data MatchResult = MatchYes [(Name Exp, Exp)]
                 | MatchMaybe
                 | MatchNo
                 deriving Show

mergeMatches :: [MatchResult] -> MatchResult
mergeMatches []     = MatchYes []
mergeMatches (m:ms) = case mergeMatches ms of
      MatchYes bs -> case m of
            MatchYes bs' -> MatchYes $ bs' ++ bs
            MatchNo      -> MatchNo
            MatchMaybe   -> MatchMaybe
      MatchNo     -> MatchNo
      MatchMaybe  -> case m of
            MatchYes _ -> MatchMaybe
            MatchNo    -> MatchNo
            MatchMaybe -> MatchMaybe

matchPat :: Exp -> Pat -> MatchResult
matchPat e = \ case
      PatCon _ _ (Embed i) pats -> case flattenApp e of
            Con _ _ c : es
                  | c == i && length es == length pats -> mergeMatches $ zipWith matchPat es pats
                  | otherwise                          -> MatchNo
            _                                          -> MatchMaybe
      PatVar _ _ x            -> MatchYes [(x, e)]
