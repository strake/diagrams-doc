module Xml2Html where

import           Control.Arrow
import           Control.Monad                      (unless)
import           Data.List                          (findIndex)
import           Data.Ord                           (Ordering (..), comparing)
import           System.Directory                   (createDirectoryIfMissing)
import           System.Exit
import           System.FilePath                    (joinPath, splitPath, (<.>),
                                                     (</>))
import           System.IO                          (stdout, stderr, hFlush, hPutStrLn)

import qualified Diagrams.Builder                   as DB
import           Diagrams.Prelude                   (V2 (..), centerXY, pad,
                                                     zero, (&), (.~))
import           Diagrams.Size                      (dims)
import           Text.Docutils.CmdLine
import           Text.Docutils.Transformers.Haskell
import           Text.Docutils.Util
import           Text.Docutils.Writers.HTML
import           Text.XML.HXT.Core                  hiding (when)

import qualified Codec.Picture                      as JP
import           Diagrams.Backend.Rasterific


xml2Html :: DocutilOpts -> IO ExitCode
xml2Html opts = do
  -- (modMap, nameMap) <- buildPackageMaps
  --                      [ "monoid-extras"
  --                      , "dual-tree"
  --                      , "diagrams-core"
  --                      , "active"
  --                      , "diagrams-lib"
  --                      , "diagrams-contrib"
  --                      , "diagrams-solve"
  --                      , "palette"
  --                      , "SVGFonts"
  --                      ]
  -- let transf = diagramsDoc modMap nameMap
  let transf = diagramsDoc () ()

  [rc] <- runX (application [withValidate no] opts transf)
  if rc >= c_err && not (keepGoing opts)
    then return (ExitFailure (-1))
    else return ExitSuccess

diagramsDoc modMap nameMap outDir =
  doTransforms [ linkifyGithub
               , linkifyHackage
               -- , linkifyModules modMap
               , highlightInlineHS
               , highlightBlockHS
               , compileDiagrams outDir
               , compileDiagramsLHS outDir
               -- , linkifyHS preference nameMap modMap
               ]
  >>> xml2html
  >>> doTransforms [ styleFile "css/default.css"
                   , styleFile "css/syntax.css"
                   , mkCallout "todo" "info"
                   , mkCallout "warning" "warning"
                   , mkPanel "exercises" "success"
                   , mkPanel "dia-lhs" "default"
                   -- , mkPanel "exampleimg" "default"
                   -- actually think it looks better not to wrap bare
                   -- example images in a panel

                   , sidebarTOC
                   ]

preference :: String -> String -> Ordering
preference = comparing (flip findIndex badModules . (==))
  -- Nothing < Just, so modules not in the list will be preferred.
  -- Modules in the list will be preferred in the order listed, from
  -- most to least preferred.
  where
    badModules = ["Diagrams.ThreeD", "Diagrams.TwoD", "Diagrams", "Diagrams.Prelude"]

mkCallout :: ArrowXml a => String -> String -> XmlT a
mkCallout cls calloutType =
  onElemA "div" [("class", cls)] $
    eelem "div"
      += attr "class" (txt (cls ++ " bs-callout bs-callout-" ++ calloutType))
      += getChildren

mkPanel :: ArrowXml a => String -> String -> XmlT a
mkPanel cls panelType =
  onElemA "div" [("class", cls)] $
    eelem "div"
      += attr "class" (txt (cls ++ " panel panel-" ++ panelType))
      += (eelem "div"
            += attr "class" (txt "panel-body")
            += getChildren
         )

sidebarTOC :: ArrowXml a => XmlT a
sidebarTOC =
  onElemA "div" [("class", "document")] $
    eelem "div"
      += attr "class" (txt "container bs-docs-container")
      += (eelem "div"
            += attr "class" (txt "row")
            += (eelem "div"
                  += attr "class" (txt "col-md-3")
                  += (eelem "div"
                        += attr "class" (txt "bs-sidebar hidden-print")
                        += attr "role" (txt "complementary")
                        += attr "data-spy" (txt "affix")
                        += (getChildren >>> isTOC >>>
                            getChildren >>> isElem >>> hasName "ul" >>> addAttr "class" "nav bs-sidenav" >>>
                              -- get rid of <h2>Contents</h2>
                            doTransforms
                              [ onElem "p" $ getChildren  -- get rid of <p> nodes
                              , onElem "ul" $ addAttr "class" "nav"
                              ]
                           )
                     )
                )
             += (eelem "div"
                   += attr "class" (txt "col-md-9")
                   += (getChildren >>> neg isTOC)
                )
         )

isTOC :: ArrowXml a => a XmlTree XmlTree
isTOC = isElem >>> hasAttrValue "class" (=="contents")

linkifyGithub :: ArrowXml a => XmlT a
linkifyGithub =
  onElemA "literal" [("classes", "repo")] $
    removeAttr "classes" >>>
    eelem "span"
      += attr "class" (txt "repo")
      += mkLink (getChildren >>> getText >>> arr (githubPrefix ++))

githubPrefix = "http://github.com/diagrams/"

compileDiagrams :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiagrams outDir = onElemA "literal_block" [("classes", "dia")] $
  eelem "div"
    += attr "class" (txt "exampleimg")
    += compileDiaArr outDir

-- | Compile code blocks intended to generate both a diagram and the
--   syntax highlighted code.
compileDiagramsLHS :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiagramsLHS outDir = onElemA "literal_block" [("classes", "dia-lhs")] $
  eelem "div"
    += attr "class" (txt "dia-lhs")
    += (compileDiaArr outDir <+> highlightBlockHSArr)

compileDiaArr :: FilePath -> XmlT (IOSLA (XIOState ()))
compileDiaArr outDir =
  getChildren >>>
  getText >>>
  diagramOrPlaceholder outDir >>>
  eelem "div"
    += attr "style" (txt "text-align: center")
    += (eelem "img"
         += attr "src" (dropPrefix outDir ^>> mkText)
         += attr "width" (txt "500")
         += attr "height" (txt "200")
       )

dropPrefix :: FilePath -> FilePath -> FilePath
dropPrefix pre = joinPath . drop (n-1) . splitPath
  where n = length (splitPath pre)

diagramOrPlaceholder :: FilePath -> IOSLA (XIOState s) String String
diagramOrPlaceholder outdir =
  arrIO (compileDiagram outdir) >>> (missing ||| passthrough)
  where
    missing = issueErr "diagram could not be rendered" >>^ (const "default.png")
    passthrough = arr id

-- | Compile the literate source code of a diagram to a .png file with
--   a file name given by a hash of the source code contents
compileDiagram :: FilePath -> String -> IO (Either String String)
compileDiagram outDir src = do
  createDirectoryIfMissing True outDir

  let bopts = DB.mkBuildOpts
                Rasterific
                (zero :: V2 Double)
                (RasterificOptions (dims $ V2 1000 400))
                & DB.snippets .~ [src]
                & DB.imports  .~
                  [ "Data.Typeable"
                  , "Diagrams.Backend.Rasterific"
                  , "Graphics.SVGFonts"
                  ]
                & DB.qimports .~ [("Graphics.SVGFonts", "SF")]
                & DB.pragmas .~ ["DeriveDataTypeable", "MultiParamTypeClasses"]
                & DB.diaExpr .~ "example"
                & DB.postProcess .~ (pad 1.1 . centerXY)
                & DB.decideRegen .~
                  (DB.hashedRegenerate
                    (\_ opts -> opts)
                    outDir
                  )

  res <- DB.buildDiagram bopts

  case res of
    DB.ParseErr err    -> do
      hPutStrLn stderr ("\nError while parsing\n" ++ src)
      hPutStrLn stderr err
      return $ Left "Error while parsing"

    DB.InterpErr ierr  -> do
      hPutStrLn stderr ("\nError while interpreting\n" ++ src)
      hPutStrLn stderr (DB.ppInterpError ierr)
      return $ Left "Error while interpreting"

    DB.Skipped hash    -> do
      putStr "."
      hFlush stdout
      return $ Right (mkFile (DB.hashToHexStr hash))

    DB.OK hash out -> do
      putStr "O"
      hFlush stdout
      JP.savePngImage (mkFile (DB.hashToHexStr hash)) (JP.ImageRGBA8 out)
      return $ Right (mkFile (DB.hashToHexStr hash))

 where
  mkFile base = outDir </> base <.> "png"
