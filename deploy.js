const Unitroller = artifacts.require("Unitroller");
const ComptrollerG6 = artifacts.require("ComptrollerG6");
const JumpRateModelV2 = artifacts.require("JumpRateModelV2");
const ERC20Mock = artifacts.require("ERC20Mock");
const Oracle = artifacts.require("SimplePriceOracle");
const CErc20 = artifacts.require("CErc20");
const CErc20Delegate = artifacts.require("CErc20Delegate");
const CErc20Delegator = artifacts.require("CErc20Delegator");

const CUpgradeTest = artifacts.require("CUpgradeTest");
const fs = require('fs');
const BigNumber = require('bignumber.js');

const D = console.log;

const bn = x=>(new BigNumber(x));
const uDecimals = bn('1e18')

// truffle --network=develop exec deploy.js
const TestAddresses = [
    "0x7A6Ed0a905053A21C15cB5b4F39b561B6A3FE50f",
    "0x7A6Ed0a905053A21C15cB5b4F39b561B6A3FE50f",
]

async function getPirce(cToken, price) {
    // uPirce * uDecimals / tokenDecimals
    // wbtcPrice = 50000 * 1e18 / 1e8
    const ctoken= await CErc20.at(cToken);
    const underlying = await ctoken.underlying();
    const uToken = await ERC20Mock.at(underlying);
    const decimals = await uToken.decimals();
    return bn(price).multipliedBy('1e18').multipliedBy(uDecimals).dividedToIntegerBy(`1e${decimals}`);
}

function easyObj(obj){
    return Object.keys(obj).filter(key=>isNaN(Number(key))).reduce(
        (robj,key)=>{
            const value = obj[key];
            if (value && value.constructor && value.constructor.isBN) {
                robj[key] = value.toString();
            }else{
                robj[key] = value;
            }
            return robj;
        },
    {});
}

async function mint(cToken, amount, account) {
    const cBefore = await cToken.balanceOf(account);
    const underlying = await cToken.underlying();
    const uToken = await ERC20Mock.at(underlying);
    await uToken.mint(account, amount);
    await uToken.approve(cToken.address, amount, {from:account});
    await cToken.mint(amount, {from:account});
    const cAfter = await cToken.balanceOf(account);
    D('mint:', amount.toString(), cAfter.toString());
    return cAfter - cBefore;
}

async function deployCtoken(codeAddress, admin, argv) {
    const delegator = await CErc20Delegator.new(...[...argv, admin, codeAddress, '0x']);
    return await CErc20.at(delegator.address);
}

async function upgradeCtoken(cToken, codeAddress, allowResign = true, becomeImplementationData="0x") {
    const delegator = await CErc20Delegator.at(cToken.address);
    await delegator._setImplementation(codeAddress, allowResign, becomeImplementationData);
    return cToken;
}


async function deployUnitroller() {
    const unitroller = await Unitroller.new();
    const comptroller = await ComptrollerG6.new();
    await unitroller._setPendingImplementation(comptroller.address);
    await comptroller._become(unitroller.address);
    return ComptrollerG6.at(unitroller.address);
}


async function upgradeUnitroller(_unitroller, codeAddress) {
    const unitroller = await Unitroller.at(_unitroller.address);
    const comptroller = await ComptrollerG6.at(codeAddress);
    await unitroller._setPendingImplementation(comptroller.address);
    await comptroller._become(unitroller.address);
    return ComptrollerG6.at(unitroller.address);
}

async function main() {
    const accounts = await web3.eth.getAccounts();
    D("accounts", accounts);
    const comptroller = await deployUnitroller();
    D("comptroller", comptroller.address);
    const baseRatePerYear = bn("0.00e18");  // + 2% apy
    const multiplierPerYear = bn("0.25e18"); // %25 apy
    const jumpMultiplierPerYear = bn("1e18"); // max 100% apy
    const kink_ = bn("0.8e18");
    const owner = accounts[0];
    const rateModel = await JumpRateModelV2.new(
        baseRatePerYear, // 最低基础利率 2%
        multiplierPerYear,  // 目标利率 25%
        jumpMultiplierPerYear, // 最大利率 100%
        kink_, // 分段利率 80%
        owner
    );
    D(comptroller.address, rateModel.address);

    const cTokenCode = await CErc20Delegate.new();
    const btc_initialExchangeRateMantissa = bn('0.02e18')
    const wBTC = await ERC20Mock.new("wBTC", "wBTC", 8);
    const cBTC = await deployCtoken(cTokenCode.address, accounts[0], 
        [wBTC.address, comptroller.address, rateModel.address, btc_initialExchangeRateMantissa, "CBTC", "CBTC", await wBTC.decimals()]
    );
    const wETH = await ERC20Mock.new("wETH", "wETH", 18);
    const cETH = await deployCtoken(cTokenCode.address, accounts[0], 
        [wETH.address, comptroller.address, rateModel.address, btc_initialExchangeRateMantissa, "CETH", "CETH", await wETH.decimals()]
    );
    const wUSDT = await ERC20Mock.new("wUSDT", "wUSDT", 18);
    const cUSDT = await deployCtoken(cTokenCode.address, accounts[0], 
        [wUSDT.address, comptroller.address, rateModel.address, btc_initialExchangeRateMantissa, "CUSDT", "CUSDT", await wUSDT.decimals()]
    );
    const coco = await ERC20Mock.new("coco", "coco lending", 18);
    await coco.mint(comptroller.address, bn('100000000e18'));
    await comptroller.setCompAddress(coco.address);
    await comptroller._supportMarket(cBTC.address);
    await comptroller._supportMarket(cETH.address);
    await comptroller._supportMarket(cUSDT.address);
    await comptroller._setCloseFactor(bn('0.3e18'));
    const marketBTC = await comptroller.markets(cBTC.address);
    const marketETH = await comptroller.markets(cETH.address);
    const marketUSDT = await comptroller.markets(cUSDT.address);
    D("market BTC:", easyObj(marketBTC));
    D("market ETH:", easyObj(marketETH));
    D("market USDT:", easyObj(marketUSDT));
    const underlying = await cETH.underlying();
    D("underlying eth:", underlying);
    const oracle = await Oracle.new();
    const btcPrice = await getPirce(cBTC.address, 50000);
    const ethPrice = await getPirce(cETH.address, 4000);
    const usdtPrice = await getPirce(cUSDT.address, 1);
    await oracle.setUnderlyingPrice(cBTC.address, btcPrice);
    await oracle.setUnderlyingPrice(cETH.address, ethPrice);
    await oracle.setUnderlyingPrice(cUSDT.address, usdtPrice);
    await comptroller._setPriceOracle(oracle.address);
    await comptroller._setCollateralFactor(cETH.address, bn('0.6e18'));
    await comptroller._setCollateralFactor(cBTC.address, bn('0.6e18'));
    await comptroller._setCollateralFactor(cUSDT.address, bn('0.6e18'));
    await comptroller._setLiquidationIncentive(bn('1.1e18'));
    const reserveFactorMantissa = bn('0.075e18');
    await cETH._setReserveFactor(reserveFactorMantissa);
    await cBTC._setReserveFactor(reserveFactorMantissa);
    await cUSDT._setReserveFactor(reserveFactorMantissa);

    for(let i = 0; i < TestAddresses.length; i++){
        const tester = TestAddresses[i];
        await web3.eth.sendTransaction({from: accounts[0], to:tester, value:bn(2e18)});
        await wBTC.mint(tester, bn('1000e8'));
        await wETH.mint(tester, bn('10000e18'));
        await wUSDT.mint(tester, bn('100000000e18'));
    }
    
    if(true) {
        await mint(cETH, bn("10e18"), accounts[4]);
        await mint(cBTC, bn("1e8"), accounts[5]);
        await mint(cUSDT, bn("10000e18"), accounts[4]);

        await comptroller.enterMarkets([cETH.address, cBTC.address, cUSDT.address], {from:accounts[5]});
        //await cBTC.borrow(bn("1e8"), {from:accounts[5]});
        await cETH.borrow(bn("7.5e18"), {from:accounts[5]});
        //await cETH.borrow(bn("2e8"), {from:accounts[5]});

        D("borrowed:", (await wETH.balanceOf(accounts[5])).toString());
        //D((await wBTC.balanceOf(accounts[5])).toString());

        const ethPrice = await getPirce(cETH.address, 5000);
        await oracle.setUnderlyingPrice(cETH.address, ethPrice);

        await wETH.mint(accounts[2], bn('2e18'));
        await wETH.approve(cETH.address, bn('2e18'), {from:accounts[2]});
        await cETH.liquidateBorrow(accounts[5], bn('1e18'), cBTC.address, {from:accounts[2]});
        //const r = await cETH.liquidateBorrow.call(accounts[5], bn('1e18'), cBTC.address, {from:accounts[2]});
        D("liquidate:", Number(await cBTC.balanceOf(accounts[2])));
        //return;
    }
    const contracts =
    {
        LPS:[
            {
                name: 'WBTC',
                decimals: 8,
                collateral: true,
                underlying:wBTC.address,
                cToken:cBTC.address,
            },
            {
                name: 'WETH',
                decimals: 18,
                collateral: true,
                underlying:wETH.address,
                cToken:cETH.address,
            },
            {
                name: 'USDT',
                decimals: 18,
                collateral: true,
                underlying:wUSDT.address,
                cToken:cUSDT.address,
            },
        ],
        oracle: oracle.address,
        comptroller:comptroller.address
    };
    fs.writeFileSync('address.json', JSON.stringify(contracts));
    /*
    //D(r.toString());
    D((await wETH.balanceOf(accounts[5])).toString());
    D((await wBTC.balanceOf(accounts[5])).toString());
    //D((await wBTC.balanceOf(accounts[5])).toString());
    */
/*
    const fakeC = await CUpgradeTest.new();
    await upgradeCtoken(cETH, fakeC.address);
    await upgradeUnitroller(comptroller, fakeC.address);
    D("cName:", (await cETH.balanceOf(accounts[5])).toString(16));
    D("compRate:", (await comptroller.compRate()).toString());
*/
    //const reserveFactorMantissa = await cETH.reserveFactorMantissa();
    const closeFactorMantissa = await comptroller.closeFactorMantissa();
    const exRate = await cETH.exchangeRateStored();
    const ethBorrowRate = await cETH.borrowRatePerBlock();
    const ethSupplyRate = await cETH.supplyRatePerBlock();
    const apy = rate=>((Number(rate)*(24*3600/2)/1e18+1))**365-1;
    D("closeFactor:", Number(closeFactorMantissa)/1e18)
    D("reserveFactor:", Number(reserveFactorMantissa)/1e18)
    D("exRate:", Number(exRate)/1e18);
    D("borrow:", Number(ethBorrowRate), apy(ethBorrowRate));
    D("supply:", Number(ethSupplyRate), apy(ethSupplyRate));
}

module.exports = function (cbk) {
    main().then(cbk).catch(cbk);
};