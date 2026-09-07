// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferERC20
/// @notice 模拟带转账手续费的 ERC20（例如 Tether USDT 合约中实际存在、
///         由发行方控制、当前休眠但可被激活的 basisPointsRate 费率机制）。
///         每次 transfer/transferFrom 会扣留 feeBps 基点作为"手续费"（销毁），
///         接收方实际到账金额小于调用方传入的 amount。
contract FeeOnTransferERC20 is ERC20 {
    uint256 public feeBps; // 基点，1 = 0.01%

    constructor() ERC20("Fee On Transfer USDT", "FUSDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFee(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transferWithFee(from, to, amount);
        return true;
    }

    function _transferWithFee(address from, address to, uint256 amount) private {
        uint256 fee = (amount * feeBps) / 10_000;
        _transfer(from, to, amount - fee);
        if (fee > 0) _burn(from, fee);
    }
}
