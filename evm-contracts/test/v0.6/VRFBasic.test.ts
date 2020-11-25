import {
  contract,
  setup,
  helpers,
  matchers
} from '@chainlink/test-helpers'
import { assert } from 'chai'
import { VRFBasicFactory } from '../../ethers/v0.6/VRFBasicFactory'
import { VRFCoordinatorMockFactory } from '../../ethers/v0.6/VRFCoordinatorMockFactory'

let roles: setup.Roles
const provider = setup.provider()
const linkTokenFactory = new contract.LinkTokenFactory()
const vrfCoordinatorMockFactory = new VRFCoordinatorMockFactory()
const vrfBasicFactory = new VRFBasicFactory()

beforeAll(async () => {
  const users = await setup.users(provider)

  roles = users.roles
})

describe('VRFBasic', () => {
  const deposit = helpers.toWei('1')
  const fee = helpers.toWei('0.1')
  const keyHash = helpers.toBytes32String("keyHash")
  const seed = 12345

  let link: contract.Instance<contract.LinkTokenFactory>
  let vrfCoordinator: contract.Instance<VRFCoordinatorMockFactory>
  let vrfBasic: contract.Instance<VRFBasicFactory>

  const deployment = setup.snapshot(provider, async () => {
    link = await linkTokenFactory.connect(roles.defaultAccount).deploy()
    vrfCoordinator = await vrfCoordinatorMockFactory
      .connect(roles.defaultAccount)
      .deploy(link.address)
    vrfBasic = await vrfBasicFactory
      .connect(roles.defaultAccount)
      .deploy(vrfCoordinator.address, link.address, keyHash, fee)
    await link.transfer(vrfBasic.address, deposit)
  })

  beforeEach(async () => {
    await deployment();
  })

  describe('#getRandomNumber', () => {
    it('revert when LINK balance is zero', async () => {
      let vrfBasic2 = await vrfBasicFactory
        .connect(roles.defaultAccount)
        .deploy(vrfCoordinator.address, link.address, keyHash, fee)
      await matchers.evmRevert(async () => {
        await vrfBasic2.getRandomNumber(seed)
      })
    })

    it('emits a RandomnessRequest from the Coordinator', async () => {
      const tx = await vrfBasic.getRandomNumber(seed)
      const log = await helpers.getLog(tx, 2)
      const topics = log?.topics
      assert.equal(helpers.evmWordToAddress(topics?.[1]), vrfBasic.address)
      assert.equal(topics?.[2], keyHash)
      assert.equal(topics?.[3], helpers.numToBytes32(seed))
    })
  })

  describe('#fulfillRandomness', () => {
    const randomness = 98765
    let requestId: string
    beforeEach(async () => {
      const tx = await vrfBasic.getRandomNumber(seed)
      const log = await helpers.getLog(tx, 3)
      requestId = log?.topics?.[1]
    })

    describe('success', () => {
      it('fulfills request with randomness', async () => {
        const tx = await vrfCoordinator.callBackWithRandomness(
          requestId, randomness, vrfBasic.address
        )
        const log = await helpers.getLog(tx, 0)
        assert.equal(log?.topics[2], helpers.numToBytes32(randomness))
      })
    })

    describe('failure', () => {
      it('does not fulfill when the wrong requestId is used', async () => {
        const tx = await vrfCoordinator.callBackWithRandomness(
          helpers.toBytes32String("wrong request ID"), randomness, vrfBasic.address
        )
        const logs = await helpers.getLogs(tx)
        assert.equal(logs.length, 0)
      })

      it('does not fulfill when fulfilled by the wrong VRFcoordinator', async () => {
        let vrfCoordinator2 = await vrfCoordinatorMockFactory
          .connect(roles.defaultAccount)
          .deploy(link.address)

        const tx = await vrfCoordinator2.callBackWithRandomness(
          requestId, randomness, vrfBasic.address
        )
        const logs = await helpers.getLogs(tx)
        assert.equal(logs.length, 0)
      })
    })
  })
})