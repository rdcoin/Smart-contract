import {
  contract,
  helpers as h,
  matchers,
  setup,
} from '@chainlink/test-helpers'
import { assert } from 'chai'
import { ethers } from 'ethers'
import { AccessControlProxyFactory } from '../../ethers/v0.6/AccessControlProxyFactory'
import { MockV3AggregatorFactory } from '../../ethers/v0.6/MockV3AggregatorFactory'
import { EACAggregatorProxyFactory } from '../../ethers/v0.6/EACAggregatorProxyFactory'
import { ReaderHelperFactory } from '../../ethers/v0.6/ReaderHelperFactory'
import { SimpleAccessControlFactory } from '../../ethers/v0.6/SimpleAccessControlFactory'

let personas: setup.Personas
let defaultAccount: ethers.Wallet

const provider = setup.provider()
const accessControlProxyFactory = new AccessControlProxyFactory()
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

  let aggregator: contract.Instance<MockV3AggregatorFactory>
  let accessControlProxy: contract.Instance<AccessControlProxyFactory>
  let proxy: contract.Instance<EACAggregatorProxyFactory>
  let reader: contract.Instance<ReaderHelperFactory>
  let controller: contract.Instance<SimpleAccessControlFactory>

  const deployment = setup.snapshot(provider, async () => {
    aggregator = await aggregatorFactory
      .connect(defaultAccount)
      .deploy(decimals, 0)
    controller = await simpleAccessControlFactory
      .connect(defaultAccount)
      .deploy()
    accessControlProxy = await accessControlProxyFactory
      .connect(defaultAccount)
      .deploy(controller.address)
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
      'hasAccess',
      'hasAccessTo',
      'proposeAccessController',
      'proposedAccessController',
      'proposedHasAccess',
      'proposedHasAccessTo',
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

    it('returns the access level for queried addresses', async () => {
      assert.isFalse(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccess(reader.address, '0x00'),
      )
      await controller.addAccess(reader.address)
      assert.isTrue(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccess(reader.address, '0x00'),
      )
    })

    describe('when called from a reader through an aggregator proxy', () => {
      it('forwards requests that allow access', async () => {
        await controller.addAccess(reader.address)
        matchers.bigNum(answer, await reader.readLatestAnswer(proxy.address))
      })

      it('forwards requests that deny access', async () => {
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
      assert.isFalse(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccessTo(proxy.address, reader.address, '0x00'),
      )
      await controller.addAccess(reader.address)
      assert.isTrue(
        await accessControlProxy
          .connect(personas.Carol)
          .hasAccessTo(proxy.address, reader.address, '0x00'),
      )
    })
  })

  describe('#proposeAccessController', () => {
    let newController: contract.Instance<SimpleAccessControlFactory>

    beforeEach(async () => {
      newController = await simpleAccessControlFactory
        .connect(defaultAccount)
        .deploy()
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
    let newController: contract.Instance<SimpleAccessControlFactory>

    beforeEach(async () => {
      newController = await simpleAccessControlFactory
        .connect(defaultAccount)
        .deploy()
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
    let newController: contract.Instance<SimpleAccessControlFactory>

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
        newController = await simpleAccessControlFactory
          .connect(defaultAccount)
          .deploy()
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
    let newController: contract.Instance<SimpleAccessControlFactory>

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
        newController = await simpleAccessControlFactory
          .connect(defaultAccount)
          .deploy()
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
})
