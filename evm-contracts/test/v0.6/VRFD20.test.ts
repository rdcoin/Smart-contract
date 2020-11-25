import { contract, setup, helpers, matchers } from '@chainlink/test-helpers'
import { assert } from 'chai'
import { ContractTransaction } from 'ethers'
import { VRFD20Factory } from '../../ethers/v0.6/VRFD20Factory'
import { VRFCoordinatorMockFactory } from '../../ethers/v0.6/VRFCoordinatorMockFactory'

let roles: setup.Roles
const provider = setup.provider()
const linkTokenFactory = new contract.LinkTokenFactory()
const vrfCoordinatorMockFactory = new VRFCoordinatorMockFactory()
const vrfD20Factory = new VRFD20Factory()

beforeAll(async () => {
  const users = await setup.users(provider)

  roles = users.roles
})

describe('VRFD20', () => {
  const deposit = helpers.toWei('1')
  const fee = helpers.toWei('0.1')
  const keyHash = helpers.toBytes32String('keyHash')
  const seed = 12345

  const requestId =
    '0x66f86cab16b057baa86d6171b59e4c356197fcebc0e2cd2a744fc2d2f4dacbfe'

  let link: contract.Instance<contract.LinkTokenFactory>
  let vrfCoordinator: contract.Instance<VRFCoordinatorMockFactory>
  let vrfD20: contract.Instance<VRFD20Factory>

  const deployment = setup.snapshot(provider, async () => {
    link = await linkTokenFactory.connect(roles.defaultAccount).deploy()
    vrfCoordinator = await vrfCoordinatorMockFactory
      .connect(roles.defaultAccount)
      .deploy(link.address)
    vrfD20 = await vrfD20Factory
      .connect(roles.defaultAccount)
      .deploy(vrfCoordinator.address, link.address, keyHash, fee)
    await link.transfer(vrfD20.address, deposit)
  })

  beforeEach(async () => {
    await deployment()
  })

  describe('#currentRollRequest', () => {
    it('returns blank bytes32 when no current roll set', async () => {
      const response = await vrfD20.currentRollRequest()
      assert.equal(response, helpers.numToBytes32(0))
    })

    it('returns the correct requestId', async () => {
      await vrfD20.rollDice(seed)
      const response = await vrfD20.currentRollRequest()
      assert.equal(response, requestId)
    })
  })

  describe('#getResult', () => {
    it('reverts when a number too high is used', async () => {
      await matchers.evmRevert(async () => {
        await vrfD20.getResult(99)
      })
    })

    it('gets a previous result', async () => {
      const randomness = 6
      const modResult = (randomness % 20) + 1
      await vrfD20.rollDice(seed)
      await vrfCoordinator.callBackWithRandomness(
        requestId,
        randomness,
        vrfD20.address,
      )
      const response = await vrfD20.getResult(0)
      assert.equal(response[1].toString(), modResult.toString())
    })
  })

  describe('#latestResult', () => {
    it('reverts when there are no results', async () => {
      await matchers.evmRevert(async () => {
        await vrfD20.latestResult()
      })
    })

    it('gets the latest result', async () => {
      const randomness = 6
      const modResult = (randomness % 20) + 1
      await vrfD20.rollDice(seed)
      await vrfCoordinator.callBackWithRandomness(
        requestId,
        randomness,
        vrfD20.address,
      )
      const response = await vrfD20.latestResult()
      assert.equal(response[1].toString(), modResult.toString())
    })
  })

  describe('#rollDice', () => {
    describe('failure', () => {
      it('reverts when LINK balance is zero', async () => {
        const vrfD202 = await vrfD20Factory
          .connect(roles.defaultAccount)
          .deploy(vrfCoordinator.address, link.address, keyHash, fee)
        await matchers.evmRevert(async () => {
          await vrfD202.rollDice(seed)
        })
      })

      it('reverts when a roll is already in progress', async () => {
        await vrfD20.rollDice(seed)
        await matchers.evmRevert(async () => {
          await vrfD20.rollDice(seed)
        })
      })
    })

    describe('success', () => {
      let tx: ContractTransaction
      beforeEach(async () => {
        tx = await vrfD20.rollDice(seed)
      })

      it('emits a RandomnessRequest event from the VRFCoordinator', async () => {
        const log = await helpers.getLog(tx, 2)
        const topics = log?.topics
        assert.equal(helpers.evmWordToAddress(topics?.[1]), vrfD20.address)
        assert.equal(topics?.[2], keyHash)
        assert.equal(topics?.[3], helpers.numToBytes32(seed))
      })

      it('sets the currentRoll requestID', async () => {
        const contractRequestId = await vrfD20.currentRollRequest()
        assert.equal(contractRequestId, requestId)
      })
    })
  })

  describe('#fulfillRandomness', () => {
    const randomness = 98765
    const modResult = (randomness % 20) + 1
    let eventRequestId: string
    beforeEach(async () => {
      const tx = await vrfD20.rollDice(seed)
      const log = await helpers.getLog(tx, 3)
      eventRequestId = log?.topics?.[1]
    })

    describe('success', () => {
      let tx: ContractTransaction
      beforeEach(async () => {
        tx = await vrfCoordinator.callBackWithRandomness(
          eventRequestId,
          randomness,
          vrfD20.address,
        )
      })

      it('emits a DiceLanded event', async () => {
        const log = await helpers.getLog(tx, 0)
        assert.equal(log?.topics[1], requestId)
        assert.equal(log?.topics[2], helpers.numToBytes32(modResult))
      })

      it('sets the correct dice roll result', async () => {
        const response = await vrfD20.latestResult()
        assert.equal(response[1].toString(), modResult.toString())
      })

      it('allows another roll', async () => {
        const newSeed = 54321
        const newRequestId =
          '0x0f0da22fed81ba133214ec54546629a1fbc1c773a9ca8ca6bb2a6709738515df'
        tx = await vrfD20.rollDice(newSeed)
        const contractRequestId = await vrfD20.currentRollRequest()
        assert.equal(contractRequestId, newRequestId)
      })
    })

    describe('failure', () => {
      it('does not fulfill when the wrong requestId is used', async () => {
        const tx = await vrfCoordinator.callBackWithRandomness(
          helpers.toBytes32String('wrong request ID'),
          randomness,
          vrfD20.address,
        )
        const logs = await helpers.getLogs(tx)
        assert.equal(logs.length, 0)
      })

      it('does not fulfill when fulfilled by the wrong VRFcoordinator', async () => {
        const vrfCoordinator2 = await vrfCoordinatorMockFactory
          .connect(roles.defaultAccount)
          .deploy(link.address)

        const tx = await vrfCoordinator2.callBackWithRandomness(
          eventRequestId,
          randomness,
          vrfD20.address,
        )
        const logs = await helpers.getLogs(tx)
        assert.equal(logs.length, 0)
      })
    })
  })
})
