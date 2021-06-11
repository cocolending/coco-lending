pragma solidity ^0.5.16;

import "./CToken.sol";
import "./PriceOracle.sol";
import "./Exponential.sol";
import "./CocoDistributorStorage.sol";
import "./Governance/Comp.sol";
import "./Unitroller.sol";
import "./fmt.sol";

contract CocoDistributor is CocoDistributorStorageV1, ExponentialNoError {
/// @notice Emitted when market comped status is changed
    event MarketComped(CToken cToken, bool isComped);

    /// @notice Emitted when COMP rate is changed
    event NewCompRate(uint oldCompRate, uint newCompRate);

    /// @notice Emitted when a new COMP speed is calculated for a market
    event CompSpeedUpdated(CToken indexed cToken, uint newSpeed);

    /// @notice Emitted when a new COMP speed is set for a contributor
    event ContributorCompSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when COMP is distributed to a supplier
    event DistributedSupplierComp(CToken indexed cToken, address indexed supplier, uint compDelta, uint compSupplyIndex);

    /// @notice Emitted when COMP is distributed to a borrower
    event DistributedBorrowerComp(CToken indexed cToken, address indexed borrower, uint compDelta, uint compBorrowIndex);

    /// @notice Emitted when COMP is granted by admin
    event CompGranted(address recipient, uint amount);


    /// @notice The threshold above which the flywheel transfers COMP, in wei
    uint public constant compClaimThreshold = 0.001e18;

    /// @notice The initial COMP index for a market
    uint224 public constant compInitialIndex = 1e36;


    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Comp Distribution ***/

    /**
     * @notice Recalculate and update COMP speeds for all COMP markets
     */
    function refreshCompSpeeds() public {
        require(msg.sender == tx.origin, "only externally owned accounts may refresh speeds");
        refreshCompSpeedsInternal();
    }

    function refreshCompSpeedsInternal() internal {
        CToken[] memory allMarkets_ = comptroller.getAllMarkets();
        for (uint i = 0; i < allMarkets_.length; i++) {
            CToken cToken = allMarkets_[i];
            Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
            _updateCompSupplyIndex(address(cToken));
            _updateCompBorrowIndex(address(cToken), borrowIndex);
        }
        PriceOracle oracle = comptroller.oracle();
        Exp memory totalUtility = Exp({mantissa: 0});
        Exp[] memory utilities = new Exp[](allMarkets_.length);
        for (uint i = 0; i < allMarkets_.length; i++) {
            CToken cToken = allMarkets_[i];
            fmt.Printf("refreshCompSpeedsInternal-2: %d %x", abi.encode(i, cToken));
            if (isComped[address(cToken)]) {
                fmt.Printf("refreshCompSpeedsInternal-2-1: %x", abi.encode(oracle));
                Exp memory assetPrice = Exp({mantissa: oracle.getUnderlyingPrice(cToken)});

                fmt.Printf("refreshCompSpeedsInternal-2-2");
                Exp memory utility = mul_(assetPrice, cToken.totalBorrows());
                fmt.Printf("refreshCompSpeedsInternal-2-3");
                utilities[i] = utility;
                totalUtility = add_(totalUtility, utility);
                fmt.Printf("refreshCompSpeedsInternal-2-4");
            }
        }

        for (uint i = 0; i < allMarkets_.length; i++) {
            CToken cToken = allMarkets_[i];
            uint newSpeed = totalUtility.mantissa > 0 ? mul_(compRate, div_(utilities[i], totalUtility)) : 0;
            compSpeeds[address(cToken)] = newSpeed;
            emit CompSpeedUpdated(cToken, newSpeed);
        }
    }

    /**
     * @notice Accrue COMP to the market by updating the supply index
     * @param cToken The market whose supply index to update
     */
    function _updateCompSupplyIndex(address cToken) internal {
        CompMarketState storage supplyState = compSupplyState[cToken];
        uint supplySpeed = compSpeeds[cToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = CToken(cToken).totalSupply();
            uint compAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(compAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            compSupplyState[cToken] = CompMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    /**
     * @notice Accrue COMP to the market by updating the borrow index
     * @param cToken The market whose borrow index to update
     */
    function _updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) internal {
        CompMarketState storage borrowState = compBorrowState[cToken];
        uint borrowSpeed = compSpeeds[cToken];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(CToken(cToken).totalBorrows(), marketBorrowIndex);
            uint compAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(compAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            compBorrowState[cToken] = CompMarketState({
                index: safe224(index.mantissa, "new index exceeds 224 bits"),
                block: safe32(blockNumber, "block number exceeds 32 bits")
            });
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number exceeds 32 bits");
        }
    }

    /**
     * @notice Calculate COMP accrued by a supplier and possibly transfer it to them
     * @param cToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute COMP to
     */
    function _distributeSupplierComp(address cToken, address supplier, bool distributeAll) internal {
        CompMarketState storage supplyState = compSupplyState[cToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: compSupplierIndex[cToken][supplier]});
        compSupplierIndex[cToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = compInitialIndex;
        }
        fmt.Printf("_distributeSupplierComp sub-1: %d %d", abi.encode(supplyIndex.mantissa, supplierIndex.mantissa));
        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        fmt.Printf("_distributeSupplierComp sub-2");
        uint supplierTokens = CToken(cToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(compAccrued[supplier], supplierDelta);
        compAccrued[supplier] = transferComp(supplier, supplierAccrued, distributeAll ? 0 : compClaimThreshold);
        emit DistributedSupplierComp(CToken(cToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    /**
     * @notice Calculate COMP accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param cToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute COMP to
     */
    function _distributeBorrowerComp(address cToken, address borrower, Exp memory marketBorrowIndex, bool distributeAll) internal {
        CompMarketState storage borrowState = compBorrowState[cToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: compBorrowerIndex[cToken][borrower]});
        compBorrowerIndex[cToken][borrower] = borrowIndex.mantissa;
        fmt.Printf("borrowerIndex.mantissa:%d", abi.encode(borrowerIndex.mantissa));
        if (borrowerIndex.mantissa > 0) {

            fmt.Printf("_distributeBorrowerComp sub-1: %d %d", abi.encode(borrowIndex.mantissa, borrowerIndex.mantissa));
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            fmt.Printf("_distributeBorrowerComp sub-2: %d %d", abi.encode(borrowIndex.mantissa, borrowerIndex.mantissa));
            uint borrowerAmount = div_(CToken(cToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(compAccrued[borrower], borrowerDelta);
            compAccrued[borrower] = transferComp(borrower, borrowerAccrued, distributeAll ? 0 : compClaimThreshold);
            emit DistributedBorrowerComp(CToken(cToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Transfer COMP to the user, if they are above the threshold
     * @dev Note: If there is not enough COMP, we do not perform the transfer all.
     * @param user The address of the user to transfer COMP to
     * @param userAccrued The amount of COMP to (possibly) transfer
     * @return The amount of COMP which was NOT transferred to the user
     */
    function transferComp(address user, uint userAccrued, uint threshold) internal returns (uint) {
        if (userAccrued >= threshold && userAccrued > 0) {
            Comp comp = Comp(coco);
            uint compRemaining = comp.balanceOf(address(this));
            if (userAccrued <= compRemaining) {
                comp.transfer(user, userAccrued);
                return 0;
            }
        }
        return userAccrued;
    }

    /**
     * @notice Calculate additional accrued COMP for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint compSpeed = compContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
            fmt.Printf("updateContributorRewards sub-1: %d %d", abi.encode(blockNumber, lastContributorBlock[contributor]));
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
            fmt.Printf("updateContributorRewards sub-2: %d %d");
        if (deltaBlocks > 0 && compSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, compSpeed);
            uint contributorAccrued = add_(compAccrued[contributor], newAccrued);

            compAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the comp accrued by holder in all markets
     * @param holder The address to claim COMP for
     */
    function claimComp(address holder) public {
        CToken[] memory allMarkets = comptroller.getAllMarkets();
        return claimComp(holder, allMarkets);
    }

    /**
     * @notice Claim all the comp accrued by holder in the specified markets
     * @param holder The address to claim COMP for
     * @param cTokens The list of markets to claim COMP in
     */
    function claimComp(address holder, CToken[] memory cTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimComp(holders, cTokens, true, true);
    }

    /**
     * @notice Claim all comp accrued by the holders
     * @param holders The addresses to claim COMP for
     * @param cTokens The list of markets to claim COMP in
     * @param borrowers Whether or not to claim COMP earned by borrowing
     * @param suppliers Whether or not to claim COMP earned by supplying
     */
    function claimComp(address[] memory holders, CToken[] memory cTokens, bool borrowers, bool suppliers) public {
        for (uint i = 0; i < cTokens.length; i++) {
            CToken cToken = cTokens[i];
            require(comptroller.markets(address(cToken)), "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
                _updateCompBorrowIndex(address(cToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    _distributeBorrowerComp(address(cToken), holders[j], borrowIndex, true);
                }
            }
            if (suppliers == true) {
                _updateCompSupplyIndex(address(cToken));
                for (uint j = 0; j < holders.length; j++) {
                    _distributeSupplierComp(address(cToken), holders[j], true);
                }
            }
        }
    }

    /**
     * @notice Transfer COMP to the user
     * @dev Note: If there is not enough COMP, we do not perform the transfer all.
     * @param user The address of the user to transfer COMP to
     * @param amount The amount of COMP to (possibly) transfer
     * @return The amount of COMP which was NOT transferred to the user
     */
    function grantCompInternal(address user, uint amount) internal returns (uint) {
        Comp comp = Comp(coco);
        uint compRemaining = comp.balanceOf(address(this));
        if (amount <= compRemaining) {
            comp.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /*** Comp Distribution Admin ***/

    /**
     * @notice Transfer COMP to the recipient
     * @dev Note: If there is not enough COMP, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer COMP to
     * @param amount The amount of COMP to (possibly) transfer
     */
    function _grantComp(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant comp");
        uint amountLeft = grantCompInternal(recipient, amount);
        require(amountLeft == 0, "insufficient comp for grant");
        emit CompGranted(recipient, amount);
    }

    /**
     * @notice Set COMP speed for a single contributor
     * @param contributor The contributor whose COMP speed to update
     * @param compSpeed New COMP speed for contributor
     */
    function _setContributorCompSpeed(address contributor, uint compSpeed) public {
        require(adminOrInitializing(), "only admin can set comp speed");

        // note that COMP speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (compSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        }
        lastContributorBlock[contributor] = getBlockNumber();
        compContributorSpeeds[contributor] = compSpeed;

        emit ContributorCompSpeedUpdated(contributor, compSpeed);
    }

    /**
     * @notice Set the amount of COMP distributed per block
     * @param compRate_ The amount of COMP wei per block to distribute
     */
    function _setCompRate(uint compRate_) public {
        require(adminOrInitializing(), "only admin can change comp rate");

        uint oldRate = compRate;
        compRate = compRate_;
        emit NewCompRate(oldRate, compRate_);

        refreshCompSpeedsInternal();
    }

    /**
     * @notice Add markets to compMarkets, allowing them to earn COMP in the flywheel
     * @param cTokens The addresses of the markets to add
     */
    function _addCompMarkets(address[] memory cTokens) public {
        require(adminOrInitializing(), "only admin can add comp market");

        for (uint i = 0; i < cTokens.length; i++) {
            fmt.Printf("_addCompMarkets: %d %x", abi.encode(i, cTokens[i]));
            _addCompMarketInternal(cTokens[i]);
        }

        fmt.Printf("refreshCompSpeedsInternal");
        refreshCompSpeedsInternal();
    }

    function _addCompMarketInternal(address cToken) internal {
        require(comptroller.markets(cToken) == true, "comp market is not listed");
        require(isComped[cToken] == false, "comp market already added");

        isComped[cToken] = true;

        emit MarketComped(CToken(cToken), true);

        if (compSupplyState[cToken].index == 0 && compSupplyState[cToken].block == 0) {
            compSupplyState[cToken] = CompMarketState({
                index: compInitialIndex,
                block: safe32(getBlockNumber(), "block number exceeds 32 bits")
            });
        }

        if (compBorrowState[cToken].index == 0 && compBorrowState[cToken].block == 0) {
            compBorrowState[cToken] = CompMarketState({
                index: compInitialIndex,
                block: safe32(getBlockNumber(), "block number exceeds 32 bits")
            });
        }
    }

    /**
     * @notice Remove a market from compMarkets, preventing it from earning COMP in the flywheel
     * @param cToken The address of the market to drop
     */
    function _dropCompMarket(address cToken) public {
        require(msg.sender == admin, "only admin can drop comp market");

        require(isComped[cToken] == true, "market is not a comp market");

        isComped[cToken] = false;

        emit MarketComped(CToken(cToken), false);

        refreshCompSpeedsInternal();
    }


    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function setCoco(address _coco) external {
        require(adminOrInitializing(), "only admin can set coco token");
        coco = _coco;
    }

    function setComptroller(IComptroller _comptroller) external {
        require(adminOrInitializing(), "only admin can set comptroller");
        comptroller = _comptroller;
    }

    // interface
    modifier onlyComptroller(){require(msg.sender == address(comptroller), "onlyComptroller");_;}
    function distributeSupplierComp(address cToken, address supplier, bool distributeAll) external onlyComptroller {
        _distributeSupplierComp(cToken, supplier, distributeAll);
    }
    function updateCompSupplyIndex(address cToken) external onlyComptroller {
        _updateCompSupplyIndex(cToken);
    }
    function distributeBorrowerComp(address cToken, address borrower, uint marketBorrowIndexMantissa, bool distributeAll) external onlyComptroller {
        Exp memory marketBorrowIndex =  Exp({mantissa: marketBorrowIndexMantissa});
        _distributeBorrowerComp(cToken, borrower, marketBorrowIndex, distributeAll);
    }
    function updateCompBorrowIndex(address cToken, uint marketBorrowIndexMantissa) external onlyComptroller {
        Exp memory marketBorrowIndex =  Exp({mantissa: marketBorrowIndexMantissa});
        _updateCompBorrowIndex(cToken, marketBorrowIndex);
    }
}