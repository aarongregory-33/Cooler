// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

//import "src/Factory.sol";
//import "src/lib/mininterfaces.sol";
import {ROLESv1, RolesConsumer} from "olympus-v3/modules/ROLES/OlympusRoles.sol";
import {TRSRYv1} from "olympus-v3/modules/TRSRY/TRSRY.v1.sol";
import {MINTRv1} from "olympus-v3/modules/MINTR/MINTR.v1.sol";
import "olympus-v3/Kernel.sol";

interface IStaking {
    function unstake(
        address to,
        uint256 amount,
        bool trigger,
        bool rebasing
    ) external returns (uint256);
}

contract ClearingHouse is Policy, RolesConsumer {
    // Errors

    error OnlyFromFactory();
    error BadEscrow();
    error DurationMaximum();
    error OnlyBurnable();

    // Relevant Contracts

    CoolerFactory public immutable factory;
    ERC20 public immutable dai;
    ERC4626 public immutable sDai;
    ERC20 public immutable ohm;
    ERC20 public immutable gOHM;
    IStaking public immutable staking;

    //ERC20 public immutable dai = ERC20(0x6b175474e89094c44da98b954eedeac495271d0f);
    //ERC20 public immutable gOHM = ERC20(0x0ab87046fBb341D058F17CBC4c1133F25a20a52f);
    //IStaking public immutable staking = IStaking(0xB63cac384247597756545b500253ff8E607a8020);
    //IBurnableERC20 public immutable ohm =
    //    IBurnableERC20(0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5);

    // Modules

    TRSRYv1 public TRSRY;
    MINTRv1 public MINTR;

    // Parameter Bounds

    uint256 public constant interestRate = 5e15; // 0.5%
    uint256 public constant loanToCollateral = 3000 * 1e18; // 3,000
    uint256 public constant duration = 121 days; // Four months
    uint256 public constant fundCadence = 7 days; // One week
    uint256 public constant fundAmount = 18 * 1e24; // 18 million
    uint256 public constant liquidBalance = 3 * 1e24; // 3 million should be liquid, rest to DSR

    //constructor(address k, CoolerFactory f) Policy(Kernel(k)) {
    //factory = f;
    //}

    constructor(
        address gohm_,
        address sdai_,
        address coolerFactory_,
        address kernel_
    ) Policy(Kernel(k)) {
        gOHM = ERC20(gohm_);
        sDai = ERC4626(sdai_);
        dai = ERC20(sDai.asset());
        factory = CoolerFactory(coolerFactory_);
    }

    // Default framework setup
    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](3);
        dependencies[0] = toKeycode("TRSRY");
        dependencies[1] = toKeycode("MINTR");
        dependencies[2] = toKeycode("ROLES");

        TRSRY = TRSRYv1(getModuleAddress(toKeycode("TRSRY")));
        MINTR = MINTRv1(getModuleAddress(toKeycode("MINTR")));
        ROLES = ROLESv1(getModuleAddress(toKeycode("ROLES")));
    }

    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory requests)
    {
        requests = new Permissions[](2);
        requests[0] = Permissions(
            toKeycode("TRSRY"),
            TRSRY.withdrawReserves.selector
        );
        requests[1] = Permissions(toKeycode("MINTR"), MINTR.burnOhm.selector);
    }

    // Operation

    /// @notice lend to a cooler
    /// @param cooler to lend to
    /// @param amount of DAI to lend
    function lend(Cooler cooler, uint256 amount) external {
        // Validate
        if (!factory.created(address(cooler))) revert OnlyFromFactory();
        if (cooler.collateral() != gOHM || cooler.debt() != dai)
            revert BadEscrow();

        // Compute and access collateral
        uint256 collateral = cooler.collateralFor(amount, loanToCollateral);
        gOHM.transferFrom(msg.sender, address(this), collateral);

        // Create loan request
        gOHM.approve(address(cooler), collateral);
        uint256 id = cooler.request(
            amount,
            interestRate,
            loanToCollateral,
            duration
        );

        // Clear loan request
        dai.approve(address(cooler), amount);
        cooler.clear(id, true);
    }

    /// @notice provide terms for loan rollover
    /// @param cooler to provide terms
    /// @param id of loan in cooler
    /// @param duration of new loan
    function roll(Cooler cooler, uint256 id, uint256 duration) external {
        // Provide rollover terms
        cooler.provideNewTermsForRoll(
            id,
            interestRate,
            loanToCollateral,
            duration
        );

        // Collect applicable new collateral from user
        uint256 newCollateral = cooler.newCollateralFor(id);
        gOHM.transferFrom(msg.sender, address(this), newCollateral);

        // Roll loan
        gOHM.approve(address(cooler), newCollateral);
        cooler.roll(id);
    }

    // Funding

    // TODO can use TRSRY debt functions instead

    uint256 public fundTime; // Timestamp at which rebalancing can occur

    /// @notice fund loan liquidity from treasury
    function fund() external {
        if (fundTime == 0) fundTime = block.timestamp + fundCadence;
        else if (fundTime <= block.timestamp) fundTime += fundCadence;
        else revert("Too early to fund");

        uint256 balance = dai.balanceOf(address(this));
        if (balance < fundAmount)
            TRSRY.withdrawReserves(address(this), dai, amount);
        else dai.transfer(address(treasury), balance - fundAmount);
    }

    /// @notice rebalance liquidity between clearinghouse and DSR
    /// @dev todo
    function rebalance() external {
        uint256 balance = dai.balanceOf(address(this));
        if (balance < liquidBalance) {
            // Withdraw from DSR if available
        } else if (balance > liquidBalance) {
            // Deposit into DSR
        }
    }

    /// @notice return funds to treasury
    /// @param token to transfer
    /// @param amount to transfer
    function defund(
        ERC20 token,
        uint256 amount
    ) external onlyRole("cooler_overseer") {
        if (token == gOHM) revert OnlyBurnable();
        token.transfer(address(TRSRY), amount);
    }

    /// @notice allow any address to burn collateral returned to clearinghouse
    function burn() external {
        uint256 balance = gOHM.balanceOf(address(this));
        gOHM.approve(address(staking), balance);
        MINTR.burnOhm(staking.unstake(address(this), balance, false, false));
    }
}
