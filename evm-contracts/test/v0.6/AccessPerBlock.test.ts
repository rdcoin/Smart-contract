import {
  contract,
  helpers as h,
  matchers,
  setup,
} from '@chainlink/test-helpers'
import { assert } from 'chai'
import { ethers } from 'ethers'
import { AccessPerBlockFactory } from '../../ethers/v0.6/AccessPerBlockFactory'
import { MockV3AggregatorFactory } from '../../ethers/v0.6/MockV3AggregatorFactory'
import { EACAggregatorProxyFactory } from '../../ethers/v0.6/EACAggregatorProxyFactory'
import { ReaderHelperFactory } from '../../ethers/v0.6/ReaderHelperFactory'
import { ContractReceipt } from 'ethers/contract'
import { SimpleAccessControlFactory } from '../../ethers/v0.6/SimpleAccessControlFactory'

let personas: setup.Personas
let defaultAccount: ethers.Wallet

const provider = setup.provider()
const linkTokenFactory = new contract.LinkTokenFactory()
const paymentAccessFactory = new AccessPerBlockFactory()
const aggregatorFactory = new MockV3AggregatorFactory()
const proxyFactory = new EACAggregatorProxyFactory()
const readerHelperFactory = new ReaderHelperFactory()
const simpleAccessControlFactory = new SimpleAccessControlFactory()

beforeAll(async () => {
  const users = await setup.users(provider)

  personas = users.personas
  defaultAccount = users.roles.defaultAccount
})

describe('AccessPerBlock', () => {
  const answerNum = 470000000
  const answer = h.numToBytes32(answerNum)
  const roundId = 17
  const decimals = 8
  const timestamp = 678
  const startedAt = 677
  const multiply = 100000000 // decimals = 8
  const pricePerBlock = 1000000 // $0.01
  const maxBlocks = 5
  const staleRounds = 2
  const staleRoundDuration = 900 // 15 minutes
  const staleTimestamp = 86400 // 24 hours
  const acceptingPayments = true

  function calculatePaymentAmount(blocks: number): number {
    return Math.floor((pricePerBlock * multiply) / answerNum) * blocks
  }

  let link: contract.Instance<contract.LinkTokenFactory>
  let controller: contract.Instance<AccessPerBlockFactory>
  let aggregator: contract.Instance<MockV3AggregatorFactory>
  let proxy: contract.Instance<EACAggregatorProxyFactory>
  let reader: contract.Instance<ReaderHelperFactory>
  let previous: contract.Instance<SimpleAccessControlFactory>

  const deployment = setup.snapshot(provider, async () => {
    link = await linkTokenFactory.connect(defaultAccount).deploy()
    aggregator = await aggregatorFactory
      .connect(defaultAccount)
      .deploy(decimals, 0)
    previous = await simpleAccessControlFactory.connect(defaultAccount).deploy()
    controller = await paymentAccessFactory
      .connect(defaultAccount)
      .deploy(
        link.address,
        previous.address,
        aggregator.address,
        maxBlocks,
        staleRounds,
        staleRoundDuration,
        staleTimestamp,
        acceptingPayments,
      )
    await aggregator.updateRoundData(roundId, answer, timestamp, startedAt, roundId)
    proxy = await proxyFactory
      .connect(defaultAccount)
      .deploy(aggregator.address, controller.address)
    reader = await readerHelperFactory.connect(defaultAccount).deploy()
    await aggregator.updateAnswer(answer)
  })

  beforeEach(async () => {
    await deployment()
  })

  it('has a limited public interface', () => {
    matchers.publicAbi(paymentAccessFactory, [
      'acceptingPayments',
      'accessUntilBlock',
      'getChainlinkToken',
      'getMaxPayment',
      'getPaymentAmount',
      'hasAccess',
      'LINK',
      'maxBlocks',
      'onTokenTransfer',
      'paymentPriceFeed',
      'PREVIOUS',
      'pricePerBlock',
      'setAcceptingPayments',
      'setMaxBlocks',
      'setPaymentPriceFeed',
      'setPriceFeedTolerances',
      'setPricePerBlock',
      'staleRoundDuration',
      'staleRounds',
      'staleTimestamp',
      'withdraw',
      // Ownable methods:
      'acceptOwnership',
      'owner',
      'transferOwnership',
    ])
  })

  describe('#hasAccess', () => {
    it('allows off-chain reading', async () => {
      assert.isTrue(
        await controller
          .connect(personas.Carol)
          .hasAccess(personas.Carol.address, '0x00'),
      )
    })

    describe('when a payment amount has not been set', () => {
      it('allows access to read methods', async () => {
        matchers.bigNum(answer, await reader.readLatestAnswer(proxy.address))
      })
    })

    describe('when a payment amount has been set', () => {
      beforeEach(async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
      })

      it('allows off-chain reading', async () => {
        assert.isTrue(
          await controller
            .connect(personas.Carol)
            .hasAccess(personas.Carol.address, '0x00'),
        )
      })

      describe('when the reader has access on the previous controller', () => {
        beforeEach(async () => {
          await previous.connect(defaultAccount).addAccess(reader.address)
        })

        it('allows reading', async () => {
          assert.isTrue(await controller.hasAccess(reader.address, '0x00'))
          matchers.bigNum(answer, await reader.readLatestAnswer(proxy.address))
        })
      })

      it('does not allow reading if the caller has not paid', async () => {
        await matchers.evmRevert(async () => {
          await reader.readLatestAnswer(proxy.address)
        }, 'No access')
      })

      describe('when a reader has paid for access', () => {
        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(1),
            data,
          )
        })

        it('allows reading', async () => {
          assert.isTrue(await controller.hasAccess(reader.address, '0x00'))
          matchers.bigNum(answer, await reader.readLatestAnswer(proxy.address))
        })

        describe('after the block has progressed beyond access', () => {
          beforeEach(async () => {
            // Mine 2 blocks to ensure the current block number is
            // passed the access block for the reader
            await h.mineBlock(provider)
            await h.mineBlock(provider)
          })

          it('does not allow reading', async () => {
            await matchers.evmRevert(async () => {
              await reader.readLatestAnswer(proxy.address)
            }, 'No access')
          })

          describe('when the reader renews access', () => {
            beforeEach(async () => {
              const data = ethers.utils.defaultAbiCoder.encode(
                ['address', 'address'],
                [reader.address, proxy.address],
              )
              await link.transferAndCall(
                controller.address,
                calculatePaymentAmount(1),
                data,
              )
            })

            it('allows access again', async () => {
              assert.isTrue(await controller.hasAccess(reader.address, '0x00'))
              matchers.bigNum(
                answer,
                await reader.readLatestAnswer(proxy.address),
              )
            })
          })
        })
      })
    })
  })

  describe('#onTokenTransfer', () => {
    describe('when not accepting payments', () => {
      beforeEach(async () => {
        await controller.connect(defaultAccount).setAcceptingPayments(false)
      })

      it('rejects payment', async () => {
        const data = ethers.utils.defaultAbiCoder.encode(
          ['address', 'address'],
          [reader.address, proxy.address],
        )
        await matchers.evmRevert(async () => {
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(1),
            data,
          )
        })
      })
    })

    describe('when a payment amount has not been set for a feed', () => {
      it('rejects payment', async () => {
        const data = ethers.utils.defaultAbiCoder.encode(
          ['address', 'address'],
          [reader.address, proxy.address],
        )
        await matchers.evmRevert(async () => {
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(1),
            data,
          )
        })
      })
    })

    describe('when a payment amount has been set for a feed', () => {
      beforeEach(async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
      })

      describe('when paying within allowed values', () => {
        let receipt: ContractReceipt

        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          const tx = await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(1),
            data,
          )
          receipt = await tx.wait()
        })

        it('funds the aggregator contract', async () => {
          matchers.bigNum(
            calculatePaymentAmount(1),
            await link.balanceOf(aggregator.address),
          )
        })

        it('emits the PaymentReceived event', async () => {
          matchers.eventExists(
            receipt,
            controller.interface.events.PaymentReceived,
          )
        })
      })

      describe('when the contract is not accepting payments', () => {
        beforeEach(async () => {
          await controller.connect(defaultAccount).setAcceptingPayments(false)
        })

        it('rejects payment', async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await matchers.evmRevert(async () => {
            await link.transferAndCall(
              controller.address,
              calculatePaymentAmount(1),
              data,
            )
          })
        })
      })

      describe('when too much payment is provided', () => {
        it('rejects payment', async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await matchers.evmRevert(async () => {
            await link.transferAndCall(
              controller.address,
              calculatePaymentAmount(maxBlocks + 1),
              data,
            )
          })
        })
      })

      describe('when the user has already paid and tries to pay beyond maxBlocks', () => {
        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(maxBlocks),
            data,
          )
        })

        it('rejects payment', async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await matchers.evmRevert(async () => {
            await link.transferAndCall(
              controller.address,
              calculatePaymentAmount(maxBlocks),
              data,
            )
          })
        })
      })
    })
  })

  describe('#getChainlinkToken', () => {
    it('deploys with the specified address', async () => {
      assert.equal(link.address, await controller.getChainlinkToken())
    })
  })

  describe('#getMaxPayment', () => {
    describe('when payment has not been set', () => {
      it('returns 0', async () => {
        matchers.bigNum(
          0,
          await controller.getMaxPayment(reader.address, proxy.address),
        )
      })
    })

    describe('when payment has been set', () => {
      beforeEach(async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
      })

      describe('when the reader has not paid', () => {
        it('returns the maximum payment amount', async () => {
          matchers.bigNum(
            calculatePaymentAmount(maxBlocks),
            await controller.getMaxPayment(reader.address, proxy.address),
          )
        })
      })

      describe('when the reader has partially paid', () => {
        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(4),
            data,
          )
        })

        it('returns the expected value', async () => {
          matchers.bigNum(
            calculatePaymentAmount(1),
            await controller.getMaxPayment(reader.address, proxy.address),
          )
        })
      })

      describe('when the reader has fully paid', () => {
        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await link.transferAndCall(
            controller.address,
            calculatePaymentAmount(maxBlocks),
            data,
          )
        })

        it('returns 0', async () => {
          matchers.bigNum(
            0,
            await controller.getMaxPayment(reader.address, proxy.address),
          )
        })
      })
    })
  })

  describe('#getPaymentAmount', () => {
    describe('when a payment amount has not been set', () => {
      it('returns 0', async () => {
        matchers.bigNum(0, await controller.getPaymentAmount(proxy.address, 4))
      })
    })

    describe('when a payment amount has been set', () => {
      beforeEach(async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
      })

      it('returns the expected value', async () => {
        matchers.bigNum(
          calculatePaymentAmount(4),
          await controller.getPaymentAmount(proxy.address, 4),
        )
      })

      describe('when the rate is invalid', () => {
        beforeEach(async () => {
          await aggregator.updateAnswer(0)
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller.getPaymentAmount(proxy.address, 1)
          }, 'Invalid answer')
        })
      })

      describe('when answered in stale round', () => {
        beforeEach(async () => {
          const block = await provider.getBlock('latest')
          await aggregator.updateRoundData(
            17,
            answer,
            block?.timestamp,
            block?.timestamp,
            14,
          )
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller.getPaymentAmount(proxy.address, 1)
          }, 'Answered in stale round')
        })
      })

      describe('when the round is stale', () => {
        beforeEach(async () => {
          const round = await aggregator.latestRoundData()
          const block = await provider.getBlock('latest')
          await aggregator.updateRoundData(
            round.roundId.add(1),
            answer,
            block?.timestamp,
            0,
            round.roundId.add(1),
          )
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller.getPaymentAmount(proxy.address, 1)
          }, 'Round is stale')
        })
      })

      describe('when the answer is stale', () => {
        beforeEach(async () => {
          await h.increaseTimeBy(staleTimestamp, provider)
          await h.mineBlock(provider)
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller.getPaymentAmount(proxy.address, 1)
          }, 'Answer is stale')
        })
      })
    })
  })

  describe('#setPricePerBlock', () => {
    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(personas.Carol)
            .setPricePerBlock(proxy.address, pricePerBlock)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('sets the value', async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
        matchers.bigNum(
          pricePerBlock,
          await controller.pricePerBlock(proxy.address),
        )
      })

      it('emits the PriceSet event', async () => {
        const tx = await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
        const receipt = await tx.wait()
        matchers.eventExists(receipt, controller.interface.events.PriceSet)
      })

      describe('with the same value', () => {
        beforeEach(async () => {
          await controller
            .connect(defaultAccount)
            .setPricePerBlock(proxy.address, pricePerBlock)
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller
              .connect(defaultAccount)
              .setPricePerBlock(proxy.address, pricePerBlock)
          }, 'Price already set to value')
        })
      })
    })
  })

  describe('#setMaxBlocks', () => {
    const newMaxBlocks = 7

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller.connect(personas.Carol).setMaxBlocks(newMaxBlocks)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('sets the value', async () => {
        await controller.connect(defaultAccount).setMaxBlocks(newMaxBlocks)
        matchers.bigNum(newMaxBlocks, await controller.maxBlocks())
      })

      it('emits the MaxBlocksSet event', async () => {
        const tx = await controller
          .connect(defaultAccount)
          .setMaxBlocks(newMaxBlocks)
        const receipt = await tx.wait()
        matchers.eventExists(receipt, controller.interface.events.MaxBlocksSet)
      })

      describe('with the same value', () => {
        beforeEach(async () => {
          await controller.connect(defaultAccount).setMaxBlocks(newMaxBlocks)
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller.connect(defaultAccount).setMaxBlocks(newMaxBlocks)
          }, 'Max blocks already set to value')
        })
      })
    })
  })

  describe('#setAcceptingPayments', () => {
    const notAcceptingPayments = false

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(personas.Carol)
            .setAcceptingPayments(notAcceptingPayments)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('sets the value', async () => {
        await controller
          .connect(defaultAccount)
          .setAcceptingPayments(notAcceptingPayments)
        assert.isFalse(await controller.acceptingPayments())
      })

      it('emits the AcceptingPayments event', async () => {
        const tx = await controller
          .connect(defaultAccount)
          .setAcceptingPayments(notAcceptingPayments)
        const receipt = await tx.wait()
        matchers.eventExists(
          receipt,
          controller.interface.events.AcceptingPayments,
        )
      })

      describe('with the same value', () => {
        beforeEach(async () => {
          await controller
            .connect(defaultAccount)
            .setAcceptingPayments(notAcceptingPayments)
        })

        it('reverts', async () => {
          await matchers.evmRevert(async () => {
            await controller
              .connect(defaultAccount)
              .setAcceptingPayments(notAcceptingPayments)
          }, 'Accepting payments already set')
        })
      })
    })
  })

  describe('#setPaymentPriceFeed', () => {
    let newAggregator: contract.Instance<MockV3AggregatorFactory>

    beforeEach(async () => {
      newAggregator = await aggregatorFactory
        .connect(defaultAccount)
        .deploy(decimals, 0)
    })

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(personas.Carol)
            .setPaymentPriceFeed(newAggregator.address)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('sets the new address', async () => {
        await controller
          .connect(defaultAccount)
          .setPaymentPriceFeed(newAggregator.address)
        assert.equal(newAggregator.address, await controller.paymentPriceFeed())
      })

      it('emits the PriceFeedSet event', async () => {
        const tx = await controller
          .connect(defaultAccount)
          .setPaymentPriceFeed(newAggregator.address)
        const receipt = await tx.wait()
        matchers.eventExists(receipt, controller.interface.events.PriceFeedSet)
      })
    })
  })

  describe('#setPriceFeedTolerances', () => {
    const newStaleRounds = 4
    const newStaleRoundDuration = 901
    const newStaleTimestamp = 86401

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(personas.Carol)
            .setPriceFeedTolerances(
              newStaleRounds,
              newStaleRoundDuration,
              newStaleTimestamp,
            )
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('sets the values', async () => {
        await controller
          .connect(defaultAccount)
          .setPriceFeedTolerances(
            newStaleRounds,
            newStaleRoundDuration,
            newStaleTimestamp,
          )
        matchers.bigNum(newStaleRounds, await controller.staleRounds())
        matchers.bigNum(
          newStaleRoundDuration,
          await controller.staleRoundDuration(),
        )
        matchers.bigNum(newStaleTimestamp, await controller.staleTimestamp())
      })

      it('emits the PriceFeedTolerancesSet event', async () => {
        const tx = await controller
          .connect(defaultAccount)
          .setPriceFeedTolerances(
            newStaleRounds,
            newStaleRoundDuration,
            newStaleTimestamp,
          )
        const receipt = await tx.wait()
        matchers.eventExists(
          receipt,
          controller.interface.events.PriceFeedTolerancesSet,
        )
      })

      it('does not allow 0 values', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(defaultAccount)
            .setPriceFeedTolerances(0, newStaleRoundDuration, newStaleTimestamp)
        }, 'Can not set to zero')

        await matchers.evmRevert(async () => {
          await controller
            .connect(defaultAccount)
            .setPriceFeedTolerances(newStaleRounds, 0, newStaleTimestamp)
        }, 'Can not set to zero')

        await matchers.evmRevert(async () => {
          await controller
            .connect(defaultAccount)
            .setPriceFeedTolerances(newStaleRounds, newStaleRoundDuration, 0)
        }, 'Can not set to zero')
      })
    })
  })

  describe('#withdraw', () => {
    beforeEach(async () => {
      await link.transfer(controller.address, 1)
      matchers.bigNum(1, await link.balanceOf(controller.address))
    })

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await controller
            .connect(personas.Carol)
            .withdraw(personas.Carol.address, 1)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('transfers the LINK out of the contract', async () => {
        await controller
          .connect(defaultAccount)
          .withdraw(personas.Carol.address, 1)
        matchers.bigNum(0, await link.balanceOf(controller.address))
        matchers.bigNum(1, await link.balanceOf(personas.Carol.address))
      })
    })
  })
})
