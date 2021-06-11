const fs = require('fs');
if(!fs.existsSync('./abi')) fs.mkdirSync('./abi');
function outputABI(name) {
    const C = require(`./build/contracts/${name}.json`);
    fs.writeFileSync(`./abi/${name}.json`, JSON.stringify(C.abi));
}

[
    "ComptrollerG6",
    "CErc20",
    "EIP20Interface",
    "SimplePriceOracle",
    "CompoundLens",
    "CocoDistributor"
].forEach(outputABI);