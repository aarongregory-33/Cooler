// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @notice Allows for debt issuers to execute logic when a loan is repaid or defaulted.
interface ICoolerCallback {
    function onRepay(uint256 loanID, uint256 amount) external;
    function onDefault(uint256 loanID) external;
}