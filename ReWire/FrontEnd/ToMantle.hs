{-# LANGUAGE LambdaCase, ViewPatterns, ScopedTypeVariables #-}
{-# LANGUAGE Safe #-}
module ReWire.FrontEnd.ToMantle (toMantle) where

import ReWire.Annotation hiding (ann)
import ReWire.Error
import ReWire.FrontEnd.Fixity
import ReWire.FrontEnd.Rename hiding (Module)
import ReWire.FrontEnd.Syntax ((|->))
import ReWire.FrontEnd.Unbound
      ( string2Name, name2String
      , fresh, Fresh, Name, Embed (..), bind
      )
import ReWire.SYB

import Control.Monad (foldM, replicateM, void)
import Data.Foldable (foldl')
import Data.Monoid ((<>))
import Language.Haskell.Exts.Annotated.Fixity (Fixity (..))
import Language.Haskell.Exts.Annotated.Simplify (sName, sDeclHead, sQName, sModuleName)
import Language.Haskell.Exts.Pretty (prettyPrint)

import qualified Data.Set                     as Set
import qualified Language.Haskell.Exts.Syntax as S
import qualified ReWire.FrontEnd.Rename       as M
import qualified ReWire.FrontEnd.Syntax       as M

import Language.Haskell.Exts.Annotated.Syntax hiding (Name, Kind)

-- | An intermediate form for exports. TODO(chathhorn): get rid of it.
data Export = Export FQName
            | ExportWith FQName [FQName]
            | ExportAll FQName
            | ExportMod S.ModuleName
            | ExportFixity S.Assoc Int S.Name
      deriving Show

mkId :: String -> Name b
mkId = string2Name

mkUId :: S.Name -> Name b
mkUId (S.Ident n)  = mkId n
mkUId (S.Symbol n) = mkId n

-- | Translate a Haskell module into the ReWire abstract syntax.
toMantle :: (Fresh m, SyntaxError m) => Renamer -> Module Annote -> m (M.Module, Exports)
toMantle rn (Module _ (Just (ModuleHead _ m _ exps)) _ _ (reverse -> ds)) = do
      let rn' = extendWithGlobs (sModuleName m) ds rn
      tyDefs <- foldM (transData rn') [] ds
      tySigs <- foldM (transTySig rn') [] ds
      inls   <- foldM transInlineSig [] ds
      fnDefs <- foldM (transDef rn' tySigs inls) [] ds
      exps'  <- maybe (pure $ getGlobExps rn' ds) (\ (ExportSpecList _ exps') -> foldM (transExport rn' ds) [] exps') exps
      pure (M.Module tyDefs fnDefs, resolveExports rn exps')
      where getGlobExps :: Renamer -> [Decl Annote] -> [Export]
            getGlobExps rn ds = getExportFixities ds ++ foldr (getGlobExps' rn) [] ds

            getGlobExps' :: Renamer -> Decl Annote -> [Export] -> [Export]
            getGlobExps' rn = \ case
                  DataDecl _ _ _ hd cs _   -> (:) $ ExportWith (rename Type rn $ fst $ sDeclHead hd) $ map (rename Value rn . getCtor) cs
                  PatBind _ (PVar _ n) _ _ -> (:) $ Export $ rename Value rn $ sName n
                  _                        -> id
toMantle _ m = failAt (ann m) "Unsupported module syntax"

resolveExports :: Renamer -> [Export] -> Exports
resolveExports rn = foldr (resolveExport rn) mempty

resolveExport :: Renamer -> Export -> Exports -> Exports
resolveExport rn = \ case
      Export x               -> expValue x
      ExportAll x            -> expType x $ getCtors (qnamish x) $ allExports rn
      ExportWith x cs        -> expType x (Set.fromList cs)
      ExportMod m            -> (<> getExports m rn)
      ExportFixity asc lvl x -> expFixity asc lvl x

getExportFixities :: [Decl Annote] -> [Export]
getExportFixities = map toExportFixity . getFixities
      where toExportFixity :: Fixity -> Export
            toExportFixity (Fixity asc lvl (S.UnQual n)) = ExportFixity asc lvl n
            toExportFixity _                             = undefined

transExport :: SyntaxError m => Renamer -> [Decl Annote] -> [Export] -> ExportSpec Annote -> m [Export]
transExport rn ds exps = \ case
      EVar l x                             ->
            if finger Value rn (sQName x)
            then pure $ Export (rename Value rn $ sQName x) : fixities (qnamish x) ++ exps
            else failAt l "Unknown variable name in export list"
      EAbs l _ (sQName -> x)               ->
            if finger Type rn x
            then pure $ Export (rename Type rn x) : exps
            else failAt l "Unknown class or type name in export list"
      EThingAll l (sQName -> x)            ->
            if finger Type rn x
            then pure $ lookupCtors x : concatMap fixities (getCtors $ lookupCtors x) ++ exps
            else failAt l "Unknown class or type name in export list"
      EThingWith l (sQName -> x) cs        ->
            if and $ finger Type rn x : map (finger Value rn . unwrap) cs
            then pure $ ExportWith (rename Type rn x) (map (rename Value rn . unwrap) cs) : concatMap (fixities . unwrap) cs ++ exps
            else failAt l "Unknown class or type name in export list"
      EModuleContents _ (sModuleName -> m) ->
            pure $ ExportMod m : exps
      where unwrap :: CName Annote -> S.Name
            unwrap (VarName _ x) = sName x
            unwrap (ConName _ x) = sName x

            lookupCtors :: S.QName -> Export
            lookupCtors x = foldl' lookupCtors' (ExportAll $ rename Type rn x) (map (toExport rn) $ filter isDataDecl ds)

            isDataDecl :: Decl Annote -> Bool
            isDataDecl DataDecl {} = True
            isDataDecl _           = False

            toExport :: Renamer -> Decl Annote -> Export
            toExport rn (DataDecl _ _ _ hd cs _) = ExportWith (rename Type rn $ fst $ sDeclHead hd) $ map (toExport' rn) cs
            toExport _ _                         = undefined

            toExport' :: Renamer -> QualConDecl Annote -> FQName
            toExport' rn (QualConDecl _ _ _ (ConDecl _ (sName -> x) _)) = rename Value rn x
            toExport' _  _                                              = undefined

            lookupCtors' :: Export -> Export -> Export
            lookupCtors' (ExportWith x cs) _ = ExportWith x cs
            lookupCtors' (ExportAll x) (ExportWith x' cs)
                  | x == x'                  = ExportWith x' cs
                  | otherwise                = ExportAll x
            lookupCtors' e _                 = e

            getCtors :: Export -> [S.Name]
            getCtors (ExportWith _ cs) = map name cs
            getCtors _                 = []

            fixities :: S.Name -> [Export]
            fixities n = flip filter (getExportFixities ds) $ \ case
                  ExportFixity _ _ n' -> n == n'
                  _                   -> False

extendWithGlobs :: S.ModuleName -> [Decl Annote] -> Renamer -> Renamer
extendWithGlobs m ds rn = extend Value (zip (getGlobValDefs ds) $ map (qnamish . S.Qual m) $ getGlobValDefs ds)
                        $ extend Type  (zip (getGlobTyDefs ds)  $ map (qnamish . S.Qual m) $ getGlobTyDefs ds) rn
      where getGlobValDefs :: [Decl Annote] -> [S.Name]
            getGlobValDefs = flip foldr [] $ \ case
                  DataDecl _ _ _ _ cons _              -> (++) $ map getCtor cons
                  PatBind _ (PVar _ n) _ _             -> (:) $ sName n
                  _                                    -> id
            getGlobTyDefs :: [Decl Annote] -> [S.Name]
            getGlobTyDefs = flip foldr [] $ \ case
                  DataDecl _ _ _ hd _ _ -> (:) $ fst $ sDeclHead hd
                  _                     -> id
getCtor :: QualConDecl Annote -> S.Name
getCtor = \ case
      QualConDecl _ _ _ (ConDecl _ n _) -> sName n
      QualConDecl _ _ _ (RecDecl _ n _) -> sName n
      _                                 -> undefined

transData :: (SyntaxError m, Fresh m) => Renamer -> [M.DataDefn] -> Decl Annote -> m [M.DataDefn]
transData rn datas = \ case
      DataDecl l _ _ (sDeclHead -> hd) cs _ -> do
            let n = string2Name $ rename Type rn $ fst hd
            tvs' <- mapM (transTyVar l) $ snd hd
            ks   <- replicateM (length tvs') $ freshKVar $ name2String n
            cs'  <- mapM (transCon rn ks tvs' n) cs
            pure $ M.DataDefn l n (foldr M.KFun M.KStar ks) cs' : datas
      _                                       -> pure datas

transTySig :: (Fresh m, SyntaxError m) => Renamer -> [(S.Name, M.Ty)] -> Decl Annote -> m [(S.Name, M.Ty)]
transTySig rn sigs = \ case
      TypeSig _ names t -> do
            t' <- transTy rn [] t
            pure $ zip (map sName names) (repeat t') ++ sigs
      _                 -> pure sigs

-- I guess this doesn't need to be in the monad, really, but whatever...  --adam
-- Not sure what the boolean field means here, so we ignore it!  --adam
transInlineSig :: SyntaxError m => [S.Name] -> Decl Annote -> m [S.Name]
transInlineSig inls = \ case
      InlineSig _ _ Nothing (Qual _ _ x) -> pure $ sName x : inls
      InlineSig _ _ Nothing (UnQual _ x) -> pure $ sName x : inls
      _                                  -> pure inls

transDef :: SyntaxError m => Renamer -> [(S.Name, M.Ty)] -> [S.Name] -> [M.Defn] -> Decl Annote -> m [M.Defn]
transDef rn tys inls defs = \ case
      PatBind l (PVar _ (sName -> x)) (UnGuardedRhs _ e) Nothing -> case lookup x tys of
            Just t -> do
                  e' <- transExp rn e
                  pure $ M.Defn l (mkId $ rename Value rn x) (M.fv t |-> t) (x `elem` inls) (Embed (bind [] e')) : defs
            _      -> failAt l "No type signature for"
      _                                             -> pure defs

transTyVar :: SyntaxError m => Annote -> S.TyVarBind -> m (Name M.Ty)
transTyVar l = \ case
      S.UnkindedVar x -> pure $ mkUId x
      _               -> failAt l "Unsupported type syntax"

transCon :: (Fresh m, SyntaxError m) => Renamer -> [M.Kind] -> [Name M.Ty] -> Name M.TyConId -> QualConDecl Annote -> m M.DataCon
transCon rn ks tvs tc = \ case
      QualConDecl l Nothing _ (ConDecl _ x tys) -> do
            let tvs' = zipWith (M.TyVar l) ks tvs
            t <- foldr M.arr0 (foldl' (M.TyApp l) (M.TyCon l tc) tvs') <$> mapM (transTy rn []) tys
            return $ M.DataCon l (string2Name $ rename Value rn x) (tvs |-> t)
      d                                         -> failAt (ann d) "Unsupported ctor syntax"

transTy :: (Fresh m, SyntaxError m) => Renamer -> [S.Name] -> Type Annote -> m M.Ty
transTy rn ms = \ case
      TyForall _ Nothing (Just (CxTuple _ cs)) t   -> do
           ms' <- mapM getNad cs
           transTy rn (ms ++ ms') t
      TyApp l a b | isMonad ms a -> M.TyComp l <$> transTy rn ms a <*> transTy rn ms b
                  | otherwise    -> M.TyApp l <$> transTy rn ms a <*> transTy rn ms b
      TyCon l x                  -> pure $ M.TyCon l (string2Name $ rename Type rn x)
      TyVar l x                  -> M.TyVar l <$> freshKVar (prettyPrint x) <*> (pure $ mkUId $ sName x)
      t                          -> failAt (ann t) "Unsupported type syntax"

freshKVar :: Fresh m => String -> m M.Kind
freshKVar n = M.KVar <$> fresh (string2Name $ "?K_" ++ n)

getNad :: SyntaxError m => Asst Annote -> m S.Name
getNad = \ case
      ClassA _ (UnQual _ (Ident _ "Monad")) [TyVar _ x] -> pure $ sName x
      a                                                   -> failAt (ann a) "Unsupported typeclass constraint"

isMonad :: [S.Name] -> Type Annote -> Bool
isMonad ms = \ case
      TyApp _ (TyApp _ (TyApp _ (TyCon _ (UnQual _ (Ident _ "ReT"))) _) _) t -> isMonad ms t
      TyApp _ (TyApp _ (TyCon _ (UnQual _ (Ident _ "StT"))) _) t             -> isMonad ms t
      TyCon _ (UnQual _ (Ident _ "I"))                                       -> True
      TyVar _ (sName -> x)                                                   -> x `elem` ms
      _                                                                      -> False

transExp :: SyntaxError m => Renamer -> Exp Annote -> m M.Exp
transExp rn = \ case
      App l (App _ (Var _ (UnQual _ (Ident _ "nativeVhdl"))) (Lit _ (String _ f _))) e
                            -> M.NativeVHDL l f <$> transExp rn e
      App l (Var _ (UnQual _ (Ident _ "primError"))) (Lit _ (String _ m _))
                            -> pure $ M.Error l M.tblank m
      App l e1 e2           -> M.App l <$> transExp rn e1 <*> transExp rn e2
      Lambda l [PVar _ x] e -> do
            e' <- transExp (exclude Value [sName x] rn) e
            pure $ M.Lam l M.tblank $ bind (mkUId $ sName x) e'
      Var l x               -> pure $ M.Var l M.tblank (mkId $ rename Value rn x)
      Con l x               -> pure $ M.Con l M.tblank (string2Name $ rename Value rn x)
      Case l e [Alt _ p (UnGuardedRhs _ e1) _, Alt _ _ (UnGuardedRhs _ e2) _] -> do
            e'  <- transExp rn e
            p'  <- transPat rn p
            e1' <- transExp (exclude Value (getVars p) rn) e1
            e2' <- transExp rn e2
            pure $ M.Case l M.tblank e' (bind p' e1') (Just e2')
      Case l e [Alt _ p (UnGuardedRhs _ e1) _] -> do
            e'  <- transExp rn e
            p'  <- transPat rn p
            e1' <- transExp (exclude Value (getVars p) rn) e1
            pure $ M.Case l M.tblank e' (bind p' e1') Nothing
      e                     -> failAt (ann e) $ "Unsupported expression syntax: " ++ show (void e)
      where getVars :: Pat Annote -> [S.Name]
            getVars = runQ $ query $ \ case
                  PVar (_::Annote) x -> [sName x]
                  _                  -> []

transPat :: SyntaxError m => Renamer -> Pat Annote -> m M.Pat
transPat rn = \ case
      PApp l x ps             -> M.PatCon l (Embed M.tblank) (Embed $ string2Name $ rename Value rn x) <$> mapM (transPat rn) ps
      PVar l x                -> pure $ M.PatVar l (Embed M.tblank) (mkUId $ sName x)
      p                       -> failAt (ann p) $ "Unsupported syntax in a pattern: " ++ (show $ void p)
