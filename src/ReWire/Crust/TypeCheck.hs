{-# LANGUAGE FlexibleContexts, LambdaCase, TupleSections #-}
{-# LANGUAGE Safe #-}
--
-- This type checker is based loosely on Mark Jones's "Typing Haskell in
-- Haskell", though since we don't have type classes in core it is much
-- simpler.
--
module ReWire.Crust.TypeCheck (typeCheck) where

import ReWire.Annotation
import ReWire.Error
import ReWire.Unbound
      ( fresh, substs, aeq, Subst, runFreshMT
      , n2s, s2n
      )
import ReWire.Pretty
import ReWire.Crust.Syntax

import Control.DeepSeq (deepseq, force)
import Control.Monad.Reader (ReaderT (..), local, asks)
import Control.Monad.State (evalStateT, StateT (..), get, put, modify)
import Control.Monad (zipWithM)
import Data.List (foldl')
import Data.Map.Strict (Map)

import qualified Data.Map.Strict as Map

subst :: Subst b a => Map (Name b) b -> a -> a
subst ss = substs (Map.assocs ss)

-- Type checker for core.

type TySub = Map (Name Ty) Ty
data TCEnv = TCEnv
      { as  :: Map (Name Exp) Poly
      , cas :: Map (Name DataConId) Poly
      } deriving Show

type TCM m = ReaderT TCEnv (StateT TySub m)

typeCheck :: MonadError AstError m => FreeProgram -> m FreeProgram
typeCheck (ts, vs) = runFreshMT $ evalStateT (runReaderT (tc (ts, vs)) $ TCEnv mempty mempty) mempty

localAssumps :: MonadError AstError m => (Map (Name Exp) Poly -> Map (Name Exp) Poly) -> TCM m a -> TCM m a
localAssumps f = local (\ tce -> tce { as = f (as tce) })

localCAssumps :: MonadError AstError m => (Map (Name DataConId) Poly -> Map (Name DataConId) Poly) -> TCM m a -> TCM m a
localCAssumps f = local (\ tce -> tce { cas = f (cas tce) })

freshv :: (Fresh m, MonadError AstError m) => TCM m Ty
freshv = do
      n <- fresh $ s2n "?"
      let tv = TyVar (MsgAnnote "TypeCheck: freshv") kblank n
      modify $ Map.insert n tv
      pure tv

(@@) :: TySub -> TySub -> TySub
s1 @@ s2 = Map.mapWithKey (\ _ t -> subst s1 t) s2 `Map.union` s1

isFlex :: Name a -> Bool
isFlex = (== '?') . head . n2s

varBind :: MonadError AstError m => Annote -> Name Ty -> Ty -> TCM m TySub
varBind an u t | t `aeq` TyVar noAnn kblank u = pure mempty
               | u `elem` fv t                = failAt an $ "Occurs check fails: " ++ show u ++ ", " ++ prettyPrint t
               | otherwise                    = pure $ Map.singleton u t

mgu :: MonadError AstError m => Annote -> Ty -> Ty -> TCM m TySub
mgu an (TyApp _ tl tr) (TyApp _ tl' tr')                        = do
      s1 <- mgu an tl tl'
      s2 <- mgu an (subst s1 tr) $ subst s1 tr'
      pure $ s2 @@ s1
mgu an (TyVar _ _ u)   t             | isFlex u                 = varBind an u t
mgu an t               (TyVar _ _ u) | isFlex u                 = varBind an u t
mgu _  (TyCon _ c1)    (TyCon _ c2)  | n2s c1 == n2s c2         = pure mempty
mgu _  (TyVar _ _ v)   (TyVar _ _ u) | not (isFlex v) && v == u = pure mempty
mgu an t1 t2 = failAt an $ "Types do not unify: " ++ prettyPrint t1 ++ ", " ++ prettyPrint t2

unify :: MonadError AstError m => Annote -> Ty -> Ty -> TCM m ()
unify an t1 t2 = do
      s <- get
      u <- mgu an (subst s t1) $ subst s t2
      modify (u@@)

inst :: (Fresh m, MonadError AstError m) => Poly -> TCM m Ty
inst (Poly pt) = do
      (tvs, t) <- unbind pt
      sub      <- Map.fromList <$> mapM (\ tv -> (tv,) <$> freshv) tvs
      pure $ subst sub t

patAssumps :: Pat -> Map (Name Exp) Poly
patAssumps = flip patAssumps' mempty
      where patAssumps' :: Pat -> Map (Name Exp) Poly -> Map (Name Exp) Poly
            patAssumps' = \ case
                  PatCon _ _ _ ps      -> flip (foldr patAssumps') ps
                  PatVar _ (Embed t) n -> Map.insert n $ [] `poly` t

patHoles :: Fresh m => MatchPat -> m (Map (Name Exp) Poly)
patHoles = flip patHoles' $ pure mempty
      where patHoles' :: Fresh m => MatchPat -> m (Map (Name Exp) Poly) -> m (Map (Name Exp) Poly)
            patHoles' = \ case
                  MatchPatCon _ _ _ ps -> flip (foldr patHoles') ps
                  MatchPatVar _ t      -> (flip Map.insert ([] `poly` t) <$> fresh (s2n "PHOLE") <*>)

tcPat :: (Fresh m, MonadError AstError m) => Ty -> Pat -> TCM m Pat
tcPat t = \ case
      PatVar an _ x  -> pure $ PatVar an (Embed t) x
      PatCon an _ (Embed i) ps -> do
            cas     <- asks cas
            case Map.lookup i cas of
                  Nothing  -> failAt an $ "Unknown constructor: " ++ prettyPrint i
                  Just pta -> do
                        ta               <- inst pta
                        let (targs, tres) = flattenArrow ta
                        if length ps /= length targs
                        then failAt an "Pattern is not applied to enough arguments"
                        else do
                              ps' <- zipWithM tcPat targs ps
                              unify an t tres
                              pure $ PatCon an (Embed t) (Embed i) ps'

tcMatchPat :: (Fresh m, MonadError AstError m) => Ty -> MatchPat -> TCM m MatchPat
tcMatchPat t = \ case
      MatchPatVar an _ -> pure $ MatchPatVar an t
      MatchPatCon an _ i ps -> do
            cas     <- asks cas
            case Map.lookup i cas of
                  Nothing  -> failAt an $ "Unknown constructor: " ++ prettyPrint i
                  Just pta -> do
                        ta               <- inst pta
                        let (targs, tres) = flattenArrow ta
                        if length ps /= length targs
                        then failAt an "Pattern is not applied to enough arguments"
                        else do
                              ps' <- zipWithM tcMatchPat targs ps
                              unify an t tres
                              pure $ MatchPatCon an t i ps'

tcExp :: (Fresh m, MonadError AstError m) => Exp -> TCM m (Exp, Ty)
tcExp = \ case
      e@App {}        -> do
            let (ef:es) =  flattenApp e
            (ef', tf)   <- tcExp ef
            ress        <- mapM tcExp es
            let   es'   =  map fst ress
                  tes   =  map snd ress
            tv          <- freshv
            let tf'     =  foldr arr tv tes
            unify (ann e) tf tf'
            pure (foldl' (App $ ann e) ef' es', tv)
      Lam an _ e             -> do
            (x, e')   <- unbind e
            tvx       <- freshv
            tvr       <- freshv
            (e'', te) <- localAssumps (Map.insert x ([] `poly` tvx)) $ tcExp e'
            unify an tvr $ arr tvx te
            pure (Lam an tvx $ bind x e'', tvr)
      Var an _ v             -> do
            as <- asks as
            case Map.lookup v as of
                  Nothing -> failAt an $ "Unknown variable: " ++ show v
                  Just pt -> do
                        t <- inst pt
                        pure (Var an t v, t)
      Con an _ i      -> do
            cas <- asks cas
            case Map.lookup i cas of
                  Nothing -> failAt an $ "Unknown constructor: " ++ prettyPrint i
                  Just pt -> do
                        t <- inst pt
                        pure (Con an t i, t)
      Case an _ e e1 e2      -> do
            (p, e1')    <- unbind e1
            (e', te)    <- tcExp e
            tv          <- freshv
            p'          <- tcPat te p
            let as      = patAssumps p'
            (e1'', te1) <- localAssumps (as `Map.union`) $ tcExp e1'
            unify an tv te1
            case e2 of
                  Nothing -> pure (Case an tv e' (bind p' e1'') Nothing, tv)
                  Just e2 -> do
                        (e2', te2)  <- tcExp e2
                        unify an tv te2
                        pure (Case an tv e' (bind p' e1'') (Just e2'), tv)
      Match an _ e p f as e2 -> do
            (e', te) <- tcExp e
            tv       <- freshv
            p'       <- tcMatchPat te p
            holes    <- patHoles p'
            (_, te1) <- localAssumps (holes `Map.union`) $ tcExp $ mkApp an f as $ map fst $ Map.toList holes
            unify an tv te1
            case e2 of
                  Nothing -> pure (Match an tv e' p' f as Nothing, tv)
                  Just e2 -> do
                        (e2', te2)  <- tcExp e2
                        unify an tv te2
                        pure (Match an tv e' p' f as (Just e2'), tv)
      NativeVHDL an n e      -> do
            (e', te) <- tcExp e
            pure (NativeVHDL an n e', te)
      Error an _ m           -> do
            tv <- freshv
            pure (Error an tv m, tv)

mkApp :: Annote -> Exp -> [Exp] -> [Name Exp] -> Exp
mkApp an f as holes = foldl' (App an) f
      $ as ++ map (Var an $ TyBlank an) holes

tcDefn :: (Fresh m, MonadError AstError m) => Defn -> TCM m Defn
tcDefn d  = do
      put mempty
      let Defn an n (Embed (Poly pt)) b (Embed e) = force d
      (tvs, t) <- unbind pt
      (vs, e') <- unbind e
      let (targs, _) = flattenArrow t
      (e'', te) <- localAssumps (Map.union $ Map.fromList $ zip vs $ map (poly []) targs)
            $ tcExp e'
      let te' = iterate arrowRight t !! length vs
      unify an te' te
      s <- get
      put mempty
      let d' = Defn an n (tvs |-> t) b $ Embed $ bind vs $ subst s e''
      d' `deepseq` pure d'

tc :: (Fresh m, MonadError AstError m) => FreeProgram -> TCM m FreeProgram
tc (ts, vs) = do
      let as   =  foldr defnAssump mempty vs
          cas  =  foldr dataDeclAssumps mempty ts
      vs'      <- localAssumps (as `Map.union`) $ localCAssumps (cas `Map.union`) $ mapM tcDefn vs
      pure (ts, vs')

      where defnAssump :: Defn -> Map (Name Exp) Poly -> Map (Name Exp) Poly
            defnAssump (Defn _ n (Embed pt) _ _) = Map.insert n pt

            dataDeclAssumps :: DataDefn -> Map (Name DataConId) Poly -> Map (Name DataConId) Poly
            dataDeclAssumps (DataDefn _ _ _ cs) = flip (foldr dataConAssump) cs

            dataConAssump :: DataCon -> Map (Name DataConId) Poly -> Map (Name DataConId) Poly
            dataConAssump (DataCon _ i (Embed t)) = Map.insert i t