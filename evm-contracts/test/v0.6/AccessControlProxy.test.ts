import {
  contract,
  helpers as h,
  matchers,
  setup,
} from '@chainlink/test-helpers'
import { assert } from 'chai'
import { ethers } from 'ethers'
import { AccessControlProxyFactory } from '../../ethers/v0.6/AccessControlProxyFactory'
import { AccessPerBlockFactory } from '../../ethers/v0.6/AccessPerBlockFactory'
import { MockV3AggregatorFactory } from '../../ethers/v0.6/MockV3AggregatorFactory'
import { EACAggregatorProxyFactory } from '../../ethers/v0.6/EACAggregatorProxyFactory'
import { ReaderHelperFactory } from '../../ethers/v0.6/ReaderHelperFactory'
import { SimpleAccessControlFactory } from '../../ethers/v0.6/SimpleAccessControlFactory'

let personas: setup.Personas
let defaultAccount: ethers.Wallet

const provider = setup.provider()
const linkTokenFactory = new contract.LinkTokenFactory()
const accessControlProxyFactory = new AccessControlProxyFactory()
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

describe('AccessControlProxy', () => {
  const answerNum = 470000000
  const answer = h.numToBytes32(answerNum)
  const roundId = 17
  const decimals = 8
  const timestamp = 678
  const startedAt = 677
  const pricePerBlock = 1000000 // $0.01
  const maxBlocks = 5
  const staleRounds = 2
  const staleRoundDuration = 900 // 15 minutes
  const staleTimestamp = 86400 // 24 hours
  const acceptingPayments = true
  const paymentAmount = 212765
  const maxPaymentAmount = paymentAmount * maxBlocks

  let link: contract.Instance<contract.LinkTokenFactory>
  let aggregator: contract.Instance<MockV3AggregatorFactory>
  let accessControlProxy: contract.Instance<AccessControlProxyFactory>
  let proxy: contract.Instance<EACAggregatorProxyFactory>
  let reader: contract.Instance<ReaderHelperFactory>
  let controller: contract.Instance<AccessPerBlockFactory>
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
    accessControlProxy = await accessControlProxyFactory
      .connect(defaultAccount)
      .deploy(link.address, controller.address)
    await aggregator.updateRoundData(
      roundId,
      answer,
      timestamp,
      startedAt,
      roundId,
    )
    proxy = await proxyFactory
      .connect(defaultAccount)
      .deploy(aggregator.address, accessControlProxy.address)
    reader = await readerHelperFactory.connect(defaultAccount).deploy()
    await aggregator.updateAnswer(answer)
  })

  beforeEach(async () => {
    await deployment()
  })

  it('has a limited public interface', () => {
    matchers.publicAbi(accessControlProxyFactory, [
      'accessController',
      'confirmAccessController',
      'getChainlinkToken',
      'getMaxPayment',
      'getPaymentAmount',
      'hasAccess',
      'hasAccessTo',
      'LINK',
      'onTokenTransfer',
      'proposeAccessController',
      'proposedAccessController',
      'proposedHasAccess',
      'proposedHasAccessTo',
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
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccess(personas.Carol.address, '0x00'),
      )
    })

    describe('when called from a reader through an aggregator proxy', () => {
      it('forwards requests that allow access', async () => {
        await previous.addAccess(reader.address)
        matchers.bigNum(answer, await reader.readLatestAnswer(proxy.address))
      })

      it('forwards requests that deny access', async () => {
        await controller
          .connect(defaultAccount)
          .setPricePerBlock(proxy.address, pricePerBlock)
        await matchers.evmRevert(async () => {
          await reader.readLatestAnswer(proxy.address)
        }, 'No access')
      })
    })
  })

  describe('#hasAccessTo', () => {
    it('allows off-chain reading', async () => {
      assert.isTrue(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccessTo(proxy.address, personas.Carol.address, '0x00'),
      )
    })

    it('returns the access level for queried addresses', async () => {
      assert.isTrue(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccessTo(proxy.address, reader.address, '0x00'),
      )
      await controller
        .connect(defaultAccount)
        .setPricePerBlock(proxy.address, pricePerBlock)
      assert.isFalse(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccessTo(proxy.address, reader.address, '0x00'),
      )
    })
  })

  describe('#proposeAccessController', () => {
    let newController: contract.Instance<AccessPerBlockFactory>

    beforeEach(async () => {
      newController = await paymentAccessFactory
        .connect(defaultAccount)
        .deploy(
          link.address,
          controller.address,
          aggregator.address,
          maxBlocks,
          staleRounds,
          staleRoundDuration,
          staleTimestamp,
          acceptingPayments,
        )
    })

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(personas.Carol)
            .proposeAccessController(newController.address)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('stores the proposedAccessController', async () => {
        await accessControlProxy
          .connect(defaultAccount)
          .proposeAccessController(newController.address)
        assert.equal(
          newController.address,
          await accessControlProxy.proposedAccessController(),
        )
      })

      it('rejects the same address', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(defaultAccount)
            .proposeAccessController(controller.address)
        }, 'Must be different address')
      })
    })
  })

  describe('#confirmAccessController', () => {
    let newController: contract.Instance<AccessPerBlockFactory>

    beforeEach(async () => {
      newController = await paymentAccessFactory
        .connect(defaultAccount)
        .deploy(
          link.address,
          controller.address,
          aggregator.address,
          maxBlocks,
          staleRounds,
          staleRoundDuration,
          staleTimestamp,
          acceptingPayments,
        )
      await accessControlProxy
        .connect(defaultAccount)
        .proposeAccessController(newController.address)
      assert.equal(
        newController.address,
        await accessControlProxy.proposedAccessController(),
      )
    })

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(personas.Carol)
            .confirmAccessController(newController.address)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('updates the accessController', async () => {
        await accessControlProxy
          .connect(defaultAccount)
          .confirmAccessController(newController.address)
        assert.equal(
          newController.address,
          await accessControlProxy.accessController(),
        )
      })

      it('rejects invalid addresses', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(defaultAccount)
            .confirmAccessController(controller.address)
        }, 'Invalid accessController')
      })
    })
  })

  describe('#proposedHasAccess', () => {
    let newController: contract.Instance<AccessPerBlockFactory>

    describe('when a proposed address has not been set', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(personas.Carol)
            .proposedHasAccess(personas.Carol.address, '0x00')
        })
      })
    })

    describe('when a proposed address has been set', () => {
      beforeEach(async () => {
        newController = await paymentAccessFactory
          .connect(defaultAccount)
          .deploy(
            link.address,
            controller.address,
            aggregator.address,
            maxBlocks,
            staleRounds,
            staleRoundDuration,
            staleTimestamp,
            acceptingPayments,
          )
        await accessControlProxy
          .connect(defaultAccount)
          .proposeAccessController(newController.address)
        assert.equal(
          newController.address,
          await accessControlProxy.proposedAccessController(),
        )
      })

      it('returns the access for the proposed controller', async () => {
        assert.isTrue(
          await accessControlProxy
            .connect(personas.Carol)
            .proposedHasAccess(personas.Carol.address, '0x00'),
        )
      })
    })
  })

  describe('#proposedHasAccessTo', () => {
    let newController: contract.Instance<AccessPerBlockFactory>

    describe('when a proposed address has not been set', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(personas.Carol)
            .proposedHasAccessTo(proxy.address, personas.Carol.address, '0x00')
        })
      })
    })

    describe('when a proposed address has been set', () => {
      beforeEach(async () => {
        newController = await paymentAccessFactory
          .connect(defaultAccount)
          .deploy(
            link.address,
            controller.address,
            aggregator.address,
            maxBlocks,
            staleRounds,
            staleRoundDuration,
            staleTimestamp,
            acceptingPayments,
          )
        await accessControlProxy
          .connect(defaultAccount)
          .proposeAccessController(newController.address)
        assert.equal(
          newController.address,
          await accessControlProxy.proposedAccessController(),
        )
      })

      it('returns the access for the proposed controller', async () => {
        assert.isTrue(
          await accessControlProxy
            .connect(personas.Carol)
            .proposedHasAccessTo(proxy.address, personas.Carol.address, '0x00'),
        )
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
            accessControlProxy.address,
            paymentAmount,
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
            accessControlProxy.address,
            paymentAmount,
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
        beforeEach(async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await link.transferAndCall(
            accessControlProxy.address,
            paymentAmount,
            data,
          )
        })

        it('funds the aggregator contract', async () => {
          matchers.bigNum(
            paymentAmount,
            await link.balanceOf(aggregator.address),
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
              accessControlProxy.address,
              paymentAmount,
              data,
            )
          })
        })
      })

      describe('when using the wrong token', () => {
        let notLink: contract.Instance<contract.LinkTokenFactory>

        beforeEach(async () => {
          notLink = await linkTokenFactory.connect(defaultAccount).deploy()
        })

        it('rejects payment', async () => {
          const data = ethers.utils.defaultAbiCoder.encode(
            ['address', 'address'],
            [reader.address, proxy.address],
          )
          await matchers.evmRevert(async () => {
            await notLink.transferAndCall(
              accessControlProxy.address,
              paymentAmount,
              data,
            )
          })
        })
      })
    })
  })

  describe('#getMaxPayment', () => {
    describe('when payment has not been set', () => {
      it('returns 0', async () => {
        matchers.bigNum(
          0,
          await accessControlProxy.getMaxPayment(reader.address, proxy.address),
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
            maxPaymentAmount,
            await accessControlProxy.getMaxPayment(
              reader.address,
              proxy.address,
            ),
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
            accessControlProxy.address,
            paymentAmount * 4,
            data,
          )
        })

        it('returns the expected value', async () => {
          matchers.bigNum(
            paymentAmount,
            await accessControlProxy.getMaxPayment(
              reader.address,
              proxy.address,
            ),
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
            accessControlProxy.address,
            maxPaymentAmount,
            data,
          )
        })

        it('returns 0', async () => {
          matchers.bigNum(
            0,
            await accessControlProxy.getMaxPayment(
              reader.address,
              proxy.address,
            ),
          )
        })
      })
    })
  })

  describe('#getPaymentAmount', () => {
    describe('when a payment amount has not been set', () => {
      it('returns 0', async () => {
        matchers.bigNum(
          0,
          await accessControlProxy.getPaymentAmount(proxy.address, 4),
        )
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
          paymentAmount * 4,
          await accessControlProxy.getPaymentAmount(proxy.address, 4),
        )
      })
    })
  })

  describe('#withdraw', () => {
    beforeEach(async () => {
      await link.transfer(accessControlProxy.address, 1)
      matchers.bigNum(1, await link.balanceOf(accessControlProxy.address))
    })

    describe('when called by a stranger', () => {
      it('reverts', async () => {
        await matchers.evmRevert(async () => {
          await accessControlProxy
            .connect(personas.Carol)
            .withdraw(personas.Carol.address, 1)
        }, 'Only callable by owner')
      })
    })

    describe('when called by the owner', () => {
      it('transfers the LINK out of the contract', async () => {
        await accessControlProxy
          .connect(defaultAccount)
          .withdraw(personas.Carol.address, 1)
        matchers.bigNum(0, await link.balanceOf(accessControlProxy.address))
        matchers.bigNum(1, await link.balanceOf(personas.Carol.address))
      })
    })
  })
})
