const Unitroller = artifacts.require("./Unitroller");
const ComptrollerG6 = artifacts.require("./ComptrollerG6");

require('chai')
    .use(require('chai-as-promised'))
    .should()

    async function deployUnitroller() {
        const unitroller = await Unitroller.new();
        const comptroller = await ComptrollerG6.new();
        await unitroller._setPendingImplementation(comptroller.address);
        await comptroller._become(unitroller.address);
        return ComptrollerG6.at(unitroller.address);
    }

contract('token', ([deployer, user]) => {
    let comptroller

    beforeEach(async () => {
        comptroller = await deployUnitroller()
    })

    describe('testing token contract...', () => {
        describe('success', () => {
            it('checking token name', async () => {
                expect(await comptroller.address).to.be.eq('Decentralized Bank Currency')
            })

        })

        // describe('failure', () => {
        //     it('tokens minting should be rejected', async () => {
        //         await token.mint(user, '1', {from: user}).should.be.rejectedWith(EVM_REVERT) 
        //     })
        // })
    })

})