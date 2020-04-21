import DirectoryFileProcess from './directory_file_processor'
import { FeedConfig } from 'feeds'

describe('DirectoryFileProcessor', () => {
  const firstContractAddress = "0x02D5c618DBC591544b19d0bf13543c0728A3c4Ec"
  const secondContractAddress =  "0x0133Aa47B6197D0BA090Bf2CD96626Eb71fFd13c"
  const exampleData: object = {
    "order": [firstContractAddress, secondContractAddress],
    'contracts': {
        [secondContractAddress]: {
            "contractVersion": 2,
            "decimals": 18,
            "deviationThreshold": 2,
            "heartbeat": null,
            "marketing": {
                "decimalPlaces": 9,
                "history": false,
                "networkId": 1,
                "pair": [
                    "BTC",
                    "ETH"
                ],
                "sponsored": [
                    "Aave",
                    "bZx",
                    "1inch"
                ],
                "symbol": "Ξ",
                "visible": true
            },
            "minimumAnswers": 5,
            "name": "BTC / ETH",
            "oracles": [
                {
                    "api": "coinmarketcap",
                    "jobId": "4ff7282a1f8346d1ad99236943315d33",
                    "operator": "chainlayer"
                },
                {
                    "api": "bnc",
                    "jobId": "146f65fc35a949d9ac9c382e5d504d8a",
                    "operator": "chorusOne"
                },
                {
                    "api": "coinApi",
                    "jobId": "7a06c14f100a4a0ea2a8382d9a454d6d",
                    "operator": "certusOne"
                },
                {
                    "api": "coingecko",
                    "jobId": "2e21bbcf4a7c455e8d2cb915033755ab",
                    "operator": "honeycomb"
                },
                {
                    "api": "coinmarketcap",
                    "jobId": "4a4d255bd634455aa05ab38148296361",
                    "operator": "newRoad"
                },
                {
                    "api": "cryptocompare",
                    "jobId": "3e53cc50ce0a4dca986cb6697d1aefc1",
                    "operator": "simplyVC"
                },
                {
                    "api": "alphaVantage",
                    "jobId": "0485bd5d363e4126b385b7e11bb7bbfc",
                    "operator": "wetez"
                },
                {
                    "api": "nomics",
                    "jobId": "63d186b459754bf3871aa1f72ad6017d",
                    "operator": "figmentNetworks"
                },
                {
                    "api": "coinpaprika",
                    "jobId": "b95334b6dfbd4140be108f048f95fa6f",
                    "operator": "stakeFish"
                }
            ],
            "payment": "160000000000000000",
            "status": "live"
        },
        [firstContractAddress]: {
            "contractVersion": 2,
            "decimals": 8,
            "deviationThreshold": 1,
            "heartbeat": "1h",
            "marketing": {
                "decimalPlaces": 6,
                "history": true,
                "networkId": 1,
                "pair": [
                    "CHF",
                    "USD"
                ],
                "sponsored": [
                    "Synthetix"
                ],
                "symbol": "$",
                "visible": true
            },
            "minimumAnswers": 5,
            "name": "CHF / USD",
            "oracles": [
                {
                    "api": "1Forge",
                    "jobId": "95e3c5a381e846bbbc27a0534ac17dae",
                    "operator": "chainlink"
                },
                {
                    "api": "openExchangeRate",
                    "jobId": "c7a0315acdcd476b93c5fb0cdaaadd80",
                    "operator": "chainlayer"
                },
                {
                    "api": "polygon",
                    "jobId": "3a23fff81a3446828755d369baea2bee",
                    "operator": "fiews"
                },
                {
                    "api": "1Forge",
                    "jobId": "66cef04d785a498ea9f0ae1917785a76",
                    "operator": "linkPool"
                },
                {
                    "api": "currencyLayer",
                    "jobId": "b663a1bd619540bbb01f10d7f8fb8edb",
                    "operator": "prophet"
                },
                {
                    "api": "openExchangeRate",
                    "jobId": "fb1adfc5410e44868b543b4b4f7644d3",
                    "operator": "simplyVC"
                },
                {
                    "api": "currencyLayer",
                    "jobId": "1f56eb66af97467791aca138168d34b0",
                    "operator": "validationCapital"
                },
                {
                    "api": "fixer",
                    "jobId": "c0c4f62121764f9e9c4e025ad6cb74f1",
                    "operator": "linkForest"
                },
                {
                    "api": "alphaVantage",
                    "jobId": "609002c7becb4256b113254f7bc16a31",
                    "operator": "alphaVantage"
                }
            ],
            "payment": "160000000000000000",
            "status": "live"
        },
    }
  }

  describe('#process', () => {
    it('should create a FeedConfig from each contract, ordered by the order collection', () => {
      const processor = new DirectoryFileProcess(exampleData)
      const out = processor.process()
      expect(out[0].contractAddress).toEqual(secondContractAddress)
      expect(out[1].contractAddress).toEqual(firstContractAddress)
    });

    it('should assign the appropriate data to the FeedConfigs', () => {
      const processor = new DirectoryFileProcess(exampleData)
      const out = processor.process()
      const firstContractFeed = out[0]
      const secondContractFeed = out[1]
      const firstContractData = (exampleData as any).contracts[secondContractAddress]

      expect(firstContractFeed.listing).toEqual(firstContractData.visible)
      expect(firstContractFeed.contractVersion).toEqual(firstContractData.contractVersion)
      expect(firstContractFeed.contractType).toEqual("aggregator")
      expect(firstContractFeed.name).toEqual(firstContractData.name)
      expect(firstContractFeed.valuePrefix).toEqual(firstContractData.symbol)
      expect(firstContractFeed.pair).toEqual(firstContractData['marketing']['pair'])
      expect(firstContractFeed.heartbeat).toEqual(firstContractData.heartbeat) // TODO: convert
      expect(firstContractFeed.path).toEqual(firstContractData.something) // TODO: downcase/hyphen of pair
      expect(firstContractFeed.networkId).toEqual("mainnet")// TODO: verify
      expect(firstContractFeed.history).toEqual(firstContractData['marketing']['history'])
      expect(firstContractFeed.decimalPlaces).toEqual(firstContractData['marketing']['decimalPlaces'])
      expect(firstContractFeed.multiply).toEqual(firstContractData.decimals) //TODO -- quick verify 10^firstContractData.decimals
      expect(firstContractFeed.sponsored).toEqual(firstContractData['marketing']['sponsored'])
      expect(firstContractFeed.threshold).toEqual(firstContractData.deviationThreshold)
      expect(firstContractFeed.compareOffchain).toEqual(firstContractData['marketing']['compareOffchain']) // TODO: PR
      // TODO: PR
      // "healthPrice": "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=ethereum",
      expect(firstContractFeed.healthPrice).toEqual(firstContractData['marketing']['healthPrice'])
    });
  })
})
