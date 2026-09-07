// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITrigger {
    function trigger(uint256 minUsdtOut) external;
}

/// @dev 模拟一个带回调的恶意代币：在 transfer 时尝试重入 trigger()，并记录重入是否成功。
///      真实 PTC 没有回调，这里只是为了证明 ReentrancyGuard 确实挡住了。
contract ReentrantERC20 is ERC20 {
    address public target;
    bool public attackEnabled;
    uint256 public reentryAttempts;
    uint256 public reentrySucceeded;
    bytes public lastRevertData;

    constructor() ERC20("Evil PTC", "ePTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_) external {
        target = target_;
        attackEnabled = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (attackEnabled && from == target) {
            attackEnabled = false;
            reentryAttempts += 1;
            (bool ok, bytes memory data) = target.call(abi.encodeCall(ITrigger.trigger, (0)));
            if (ok) reentrySucceeded += 1;
            else lastRevertData = data;
        }
    }
}
