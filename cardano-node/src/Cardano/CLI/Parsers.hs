{-# LANGUAGE ApplicativeDo #-}

module Cardano.CLI.Parsers
  ( command'
  , parseLogConfigFileLast
  , parseDbPathLast
  , parseDelegationCertLast
  , parseDelegationRelatedValues
  , parseGenesisHashLast
  , parseGenesisParameters
  , parseGenesisPathLast
  , parseGenesisRelatedValues
  , parseKeyRelatedValues
  , parsePbftSigThresholdLast
  , parseRequiresNetworkMagicLast
  , parseRequiresNetworkMagic
  , parseSigningKeyLast
  , parseSlotLengthLast
  , parseSocketDirLast
  , parseTxRelatedValues
  ) where

import           Cardano.Prelude hiding (option)
import           Prelude (String)

import qualified Control.Arrow
import qualified Data.List.NonEmpty as NE
import           Data.Text (pack)
import           Data.Time (UTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Network.Socket (PortNumber)
import           Options.Applicative as OA

import           Cardano.CLI.Delegation
import           Cardano.CLI.Genesis
import           Cardano.CLI.Key
import           Cardano.CLI.Run
import           Cardano.Common.Parsers

import           Cardano.Binary (Annotated(..))
import           Cardano.Chain.Common ( Address(..), BlockCount(..), Lovelace
                                      , LovelacePortion(..), NetworkMagic(..)
                                      , decodeAddressBase58
                                      , mkLovelace, mkLovelacePortion)
import           Cardano.Chain.Genesis (FakeAvvmOptions(..), TestnetBalanceOptions(..))
import           Cardano.Chain.Slotting (EpochNumber(..))
import           Cardano.Chain.UTxO (TxId, TxIn(..), TxOut(..))
import           Cardano.Config.CommonCLI
import           Cardano.Config.Topology (NodeAddress(..), NodeHostAddress(..))
import           Cardano.Config.Types (SigningKeyFile(..))
import qualified Ouroboros.Consensus.BlockchainTime  as Consensus
import           Cardano.Crypto (RequiresNetworkMagic(..), decodeHash)
import           Cardano.Crypto.ProtocolMagic ( AProtocolMagic(..), ProtocolMagic
                                              , ProtocolMagicId(..))


-- | See the rationale for cliParseBase58Address.
cliParseLovelace :: Word64 -> Lovelace
cliParseLovelace =
  either (panic . ("Bad Lovelace value: " <>) . show) identity
  . mkLovelace

-- | Here, we hope to get away with the usage of 'error' in a pure expression,
--   because the CLI-originated values are either used, in which case the error is
--   unavoidable rather early in the CLI tooling scenario (and especially so, if
--   the relevant command ADT constructor is strict, like with ClientCommand), or
--   they are ignored, in which case they are arguably irrelevant.
--   And we're getting a correct-by-construction value that doesn't need to be
--   scrutinised later, so that's an abstraction benefit as well.
cliParseBase58Address :: Text -> Address
cliParseBase58Address =
  either (panic . ("Bad Base58 address: " <>) . show) identity
  . decodeAddressBase58

cliParseHostAddress :: String -> NodeHostAddress
cliParseHostAddress = NodeHostAddress . Just .
  maybe (panic "Bad host of target node") identity . readMaybe

cliParsePort :: Word16 -> PortNumber
cliParsePort = fromIntegral

-- | See the rationale for cliParseBase58Address.
cliParseTxId :: String -> TxId
cliParseTxId =
  either (panic . ("Bad Lovelace value: " <>) . show) identity
  . decodeHash . pack

command' :: String -> String -> Parser a -> Mod CommandFields a
command' c descr p =
    OA.command c $ info (p <**> helper) $ mconcat [
        progDesc descr
      ]

parseAddress :: String -> String -> Parser Address
parseAddress opt desc =
  option (cliParseBase58Address <$> auto)
    $ long opt <> metavar "ADDR" <> help desc

parseCertificateFile :: String -> String -> Parser CertificateFile
parseCertificateFile opt desc = CertificateFile <$> parseFilePath opt desc

parseDbPathLast :: Parser (Last FilePath)
parseDbPathLast =
  lastStrOption
    ( long "database-path"
        <> metavar "FILEPATH"
        <> help "Directory where the state is stored."
    )

parseDelegationCertLast :: Parser (Last FilePath)
parseDelegationCertLast =
  lastStrOption
    ( long "delegation-certificate"
        <> metavar "FILEPATH"
        <> help "Path to the delegation certificate."
    )

parseDelegationRelatedValues :: Parser ClientCommand
parseDelegationRelatedValues =
  subparser $ mconcat
    [ commandGroup "Delegation related commands"
    , metavar "Delegation related commands"
    , command'
        "issue-delegation-certificate"
        "Create a delegation certificate allowing the\
        \ delegator to sign blocks on behalf of the issuer"
        $ IssueDelegationCertificate
        <$> parseProtocolMagicId "protocol-magic"
        <*> ( EpochNumber
                <$> parseIntegral
                      "since-epoch"
                      "The epoch from which the delegation is valid."
              )
        <*> parseSigningKeyFile
              "secret"
              "The issuer of the certificate, who delegates\
              \ their right to sign blocks."
        <*> parseVerificationKeyFile
              "delegate-key"
              "The delegate, who gains the right to sign block."
        <*> parseNewCertificateFile "certificate"
    , command'
        "check-delegation"
        "Verify that a given certificate constitutes a valid\
        \ delegation relationship between keys."
        $ CheckDelegation
            <$> parseProtocolMagicId "protocol-magic"
            <*> parseCertificateFile
                  "certificate"
                  "The certificate embodying delegation to verify."
            <*> parseVerificationKeyFile
                  "issuer-key"
                  "The genesis key that supposedly delegates."
            <*> parseVerificationKeyFile
                  "delegate-key"
                  "The operation verification key supposedly delegated to."
      ]


parseFakeAvvmOptions :: Parser FakeAvvmOptions
parseFakeAvvmOptions =
  FakeAvvmOptions
    <$> parseIntegral "avvm-entry-count" "Number of AVVM addresses."
    <*> parseLovelace "avvm-entry-balance" "AVVM address."

parseFeePerTx :: String -> String -> Parser FeePerTx
parseFeePerTx opt desc = FeePerTx <$> parseIntegral opt desc

parseGenesisHashLast :: Parser (Last Text)
parseGenesisHashLast =
  lastStrOption
    ( long "genesis-hash"
        <> metavar "GENESIS-HASH"
        <> help "The genesis hash value."
    )

-- | Values required to create genesis.
parseGenesisParameters :: Parser GenesisParameters
parseGenesisParameters =
  GenesisParameters
    <$> parseUTCTime
          "start-time"
          "Start time of the new cluster to be enshrined in the new genesis."
    <*> parseFilePath
          "protocol-parameters-file"
          "JSON file with protocol parameters."
    <*> parseK
    <*> parseProtocolMagic
    <*> parseTestnetBalanceOptions
    <*> parseFakeAvvmOptions
    <*> parseLovelacePortionWithDefault
          "avvm-balance-factor"
          "AVVM balances will be multiplied by this factor (defaults to 1)."
          1
    <*> optional
        ( parseIntegral
            "secret-seed"
            "Optionally specify the seed of generation."
        )

parseGenesisPathLast :: Parser (Last FilePath)
parseGenesisPathLast =
  lastStrOption
    ( long "genesis-file"
        <> metavar "FILEPATH"
        <> help "The filepath to the genesis file."
    )

parseGenesisRelatedValues :: Parser ClientCommand
parseGenesisRelatedValues =
  subparser $ mconcat
    [ commandGroup "Genesis related commands"
    , metavar "Genesis related commands"
    , command' "genesis" "Create genesis."
      $ Genesis
          <$> parseNewDirectory
              "genesis-output-dir"
              "Non-existent directory where genesis JSON file and secrets shall be placed."
          <*> parseGenesisParameters
    , command'
        "dump-hardcoded-genesis"
        "Write out a hard-coded genesis."
        $ DumpHardcodedGenesis
            <$> parseNewDirectory
                  "genesis-output-dir"
                  "Non-existent directory where the genesis artifacts are to be written."
    , command' "print-genesis-hash" "Compute hash of a genesis file."
        $ PrintGenesisHash
            <$> parseGenesisFile "genesis-json"
    ]

parseK :: Parser BlockCount
parseK =
  BlockCount
    <$> parseIntegral "k" "The security parameter of the Ouroboros protocol."

parseLogConfigFileLast :: Parser (Last FilePath)
parseLogConfigFileLast =
  lastStrOption
    ( long "log-config"
    <> metavar "LOGCONFIG"
    <> help "Configuration file for logging"
    <> completer (bashCompleter "file")
    )

parseNewDirectory :: String -> String -> Parser NewDirectory
parseNewDirectory opt desc = NewDirectory <$> parseFilePath opt desc

-- | Values required to create keys and perform
-- transformation on keys.
parseKeyRelatedValues :: Parser ClientCommand
parseKeyRelatedValues =
  subparser $ mconcat
        [ commandGroup "Key related commands"
        , metavar "Key related commands"
        , command' "keygen" "Generate a signing key."
            $ Keygen
                <$> parseNewSigningKeyFile "secret"
                <*> parseFlag' GetPassword EmptyPassword
                      "no-password"
                      "Disable password protection."
        , command'
            "to-verification"
            "Extract a verification key in its base64 form."
            $ ToVerification
                <$> parseSigningKeyFile
                      "secret"
                      "Signing key file to extract the verification part from."
                <*> parseNewVerificationKeyFile "to"
        , command'
            "signing-key-public"
            "Pretty-print a signing key's verification key (not a secret)."
            $ PrettySigningKeyPublic
                <$> parseSigningKeyFile
                      "secret"
                      "Signing key to pretty-print."
        , command'
            "signing-key-address"
            "Print address of a signing key."
            $ PrintSigningKeyAddress
                <$> parseNetworkMagic
                <*> parseSigningKeyFile
                      "secret"
                      "Signing key, whose address is to be printed."
        , command'
            "migrate-delegate-key-from"
            "Migrate a delegate key from an older version."
            $ MigrateDelegateKeyFrom
                <$> parseProtocol
                <*> parseNewSigningKeyFile "to"
                <*> parseSigningKeyFile "from" "Signing key file to migrate."
        ]

parseLovelace :: String -> String -> Parser Lovelace
parseLovelace optname desc =
  either (panic . show) identity . mkLovelace
    <$> parseIntegral optname desc

parseLovelacePortion :: String -> String -> Parser LovelacePortion
parseLovelacePortion optname desc =
  either (panic . show) identity . mkLovelacePortion
    <$> parseIntegral optname desc

parseLovelacePortionWithDefault
  :: String
  -> String
  -> Word64
  -> Parser LovelacePortion
parseLovelacePortionWithDefault optname desc w =
  either (panic . show) identity . mkLovelacePortion
    <$> parseIntegralWithDefault optname desc w

parseNetworkMagic :: Parser NetworkMagic
parseNetworkMagic =
  asum [ flag' NetworkMainOrStage $ mconcat
           [ long "main-or-staging"
           , help ""
           ]
       , option (fmap NetworkTestnet auto)
           $ long "testnet-magic"
             <> metavar "MAGIC"
             <> help "The testnet network magic, decibal"
       ]

parseNewCertificateFile :: String -> Parser NewCertificateFile
parseNewCertificateFile opt =
  NewCertificateFile
    <$> parseFilePath opt "Non-existent file to write the certificate to."

parseNewSigningKeyFile :: String -> Parser NewSigningKeyFile
parseNewSigningKeyFile opt =
  NewSigningKeyFile
    <$> parseFilePath opt "Non-existent file to write the signing key to."

parseNewTxFile :: String -> Parser NewTxFile
parseNewTxFile opt =
  NewTxFile
    <$> parseFilePath opt "Non-existent file to write the signed transaction to."

parseNewVerificationKeyFile :: String -> Parser NewVerificationKeyFile
parseNewVerificationKeyFile opt =
  NewVerificationKeyFile
    <$> parseFilePath opt "Non-existent file to write the verification key to."

parseNumberOfInputsPerTx :: String -> String -> Parser NumberOfInputsPerTx
parseNumberOfInputsPerTx opt desc = NumberOfInputsPerTx <$> parseIntegral opt desc

parseNumberOfOutputsPerTx :: String -> String -> Parser NumberOfOutputsPerTx
parseNumberOfOutputsPerTx opt desc = NumberOfOutputsPerTx <$> parseIntegral opt desc

parseNumberOfTxs :: String -> String -> Parser NumberOfTxs
parseNumberOfTxs opt desc = NumberOfTxs <$> parseIntegral opt desc

parseProtocolMagicId :: String -> Parser ProtocolMagicId
parseProtocolMagicId arg =
  ProtocolMagicId
    <$> parseIntegral arg "The magic number unique to any instance of Cardano."

parsePbftSigThresholdLast :: Parser (Last Double)
parsePbftSigThresholdLast =
  lastDoubleOption
    ( long "pbft-signature-threshold"
        <> metavar "DOUBLE"
        <> help "The PBFT signature threshold."
        <> hidden
    )

parseProtocolMagic :: Parser ProtocolMagic
parseProtocolMagic =
  flip AProtocolMagic RequiresMagic . flip Annotated ()
    <$> parseProtocolMagicId "protocol-magic"

parseRequiresNetworkMagicLast :: Parser (Last RequiresNetworkMagic)
parseRequiresNetworkMagicLast =
  lastFlag RequiresNoMagic RequiresMagic
    ( long "require-network-magic"
        <> help "Require network magic in transactions."
        <> hidden
    )


parseRequiresNetworkMagic :: Parser RequiresNetworkMagic
parseRequiresNetworkMagic =
  flag RequiresNoMagic RequiresMagic
    ( long "require-network-magic"
        <> help "Require network magic in transactions."
        <> hidden
    )

parseSigningKeyFile :: String -> String -> Parser SigningKeyFile
parseSigningKeyFile opt desc = SigningKeyFile <$> parseFilePath opt desc

parseSigningKeysFiles :: String -> String -> Parser [SigningKeyFile]
parseSigningKeysFiles opt desc = some $ SigningKeyFile <$> parseFilePath opt desc

parseSigningKeyLast :: Parser (Last FilePath)
parseSigningKeyLast =
  lastStrOption
    ( long "signing-key"
        <> metavar "FILEPATH"
        <> help "Path to the signing key."
    )

parseSlotLengthLast :: Parser (Last Consensus.SlotLength)
parseSlotLengthLast = do
  slotDurInteger <- lastAutoOption
                      ( long "slot-duration"
                          <> metavar "SECONDS"
                          <> help "The slot duration (seconds)"
                          <> hidden
                      )
  pure $ mkSlotLength <$> slotDurInteger
 where
  mkSlotLength :: Integer -> Consensus.SlotLength
  mkSlotLength sI = Consensus.slotLengthFromMillisec $ 1000 * sI

parseSocketDirLast :: Parser (Last FilePath)
parseSocketDirLast =
  lastStrOption
    ( long "socket-dir"
        <> metavar "FILEPATH"
        <> help "Directory with local sockets:\
                \  ${dir}/node-{core,relay}-${node-id}.socket"
    )

parseTargetNodeAddress :: String -> String -> Parser NodeAddress
parseTargetNodeAddress optname desc =
  option
    ( uncurry NodeAddress
      . Control.Arrow.first cliParseHostAddress
      . Control.Arrow.second cliParsePort
      <$> auto
    )
    $ long optname
      <> metavar "(HOST,PORT)"
      <> help desc

parseTestnetBalanceOptions :: Parser TestnetBalanceOptions
parseTestnetBalanceOptions =
  TestnetBalanceOptions
    <$> parseIntegral
          "n-poor-addresses"
          "Number of poor nodes (with small balance)."
    <*> parseIntegral
          "n-delegate-addresses"
          "Number of delegate nodes (with huge balance)."
    <*> parseLovelace
          "total-balance"
          "Total balance owned by these nodes."
    <*> parseLovelacePortion
          "delegate-share"
          "Portion of stake owned by all delegates together."

parseTPSRate :: String -> String -> Parser TPSRate
parseTPSRate opt desc = TPSRate <$> parseIntegral opt desc

parseTxAdditionalSize :: String -> String -> Parser TxAdditionalSize
parseTxAdditionalSize opt desc = TxAdditionalSize <$> parseIntegral opt desc

parseTxFile :: String -> Parser TxFile
parseTxFile opt =
  TxFile
    <$> parseFilePath opt "File containing the signed transaction."

parseTxIn :: Parser TxIn
parseTxIn =
  option
  ( uncurry TxInUtxo
    . Control.Arrow.first cliParseTxId
    <$> auto
  )
  $ long "txin"
    <> metavar "(TXID,INDEX)"
    <> help "Transaction input is a pair of an UTxO TxId and a zero-based output index."

parseTxOut :: Parser TxOut
parseTxOut =
  option
    ( uncurry TxOut
      . Control.Arrow.first cliParseBase58Address
      . Control.Arrow.second cliParseLovelace
      <$> auto
    )
    $ long "txout"
      <> metavar "ADDR:LOVELACE"
      <> help "Specify a transaction output, as a pair of an address and lovelace."

parseTxRelatedValues :: Parser ClientCommand
parseTxRelatedValues =
  subparser $ mconcat
    [ commandGroup "Transaction related commands"
    , metavar "Transaction related commands"
    , command'
        "submit-tx"
        "Submit a raw, signed transaction, in its on-wire representation."
        $ SubmitTx
            <$> parseTxFile "tx"
            <*> parseTopologyInfo "Target node that will receive the transaction"
            <*> parseNodeId "Node Id of target node"
    , command'
        "issue-genesis-utxo-expenditure"
        "Write a file with a signed transaction, spending genesis UTxO."
        $ SpendGenesisUTxO
            <$> parseNewTxFile "tx"
            <*> parseSigningKeyFile
                  "wallet-key"
                  "Key that has access to all mentioned genesis UTxO inputs."
            <*> parseAddress
                  "rich-addr-from"
                  "Tx source: genesis UTxO richman address (non-HD)."
            <*> (NE.fromList <$> some parseTxOut)

    , command'
        "issue-utxo-expenditure"
        "Write a file with a signed transaction, spending normal UTxO."
        $ SpendUTxO
            <$> parseNewTxFile "tx"
            <*> parseSigningKeyFile
                  "wallet-key"
                  "Key that has access to all mentioned genesis UTxO inputs."
            <*> (NE.fromList <$> some parseTxIn)
            <*> (NE.fromList <$> some parseTxOut)
    , command'
        "generate-txs"
        "Launch transactions generator."
        $ GenerateTxs
            <$> (NE.fromList <$> some (
                  parseTargetNodeAddress
                    "target-node"
                    "host and port of the node transactions will be sent to."
                  )
                )
            <*> parseNumberOfTxs
                  "num-of-txs"
                  "Number of transactions generator will create."
            <*> parseNumberOfInputsPerTx
                  "inputs-per-tx"
                  "Number of inputs in each of transactions."
            <*> parseNumberOfOutputsPerTx
                  "outputs-per-tx"
                  "Number of outputs in each of transactions."
            <*> parseFeePerTx
                  "tx-fee"
                  "Fee per transaction, in Lovelaces."
            <*> parseTPSRate
                  "tps"
                  "TPS (transaction per second) rate."
            <*> optional (
                  parseTxAdditionalSize
                    "add-tx-size"
                    "Additional size of transaction, in bytes."
                )
            <*> parseSigningKeysFiles
                  "sig-key"
                  "Path to signing key file, for genesis UTxO using by generator."
            <*> parseNodeId "Node Id of target node"
      ]


parseUTCTime :: String -> String -> Parser UTCTime
parseUTCTime optname desc =
  option (posixSecondsToUTCTime . fromInteger <$> auto)
    $ long optname <> metavar "POSIXSECONDS" <> help desc

parseVerificationKeyFile :: String -> String -> Parser VerificationKeyFile
parseVerificationKeyFile opt desc = VerificationKeyFile <$> parseFilePath opt desc