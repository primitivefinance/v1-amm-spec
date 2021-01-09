pragma solidity >=0.5.16;

import '../PrimitiveERC20.sol';

contract ERC20 is PrimitiveERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
    
    function mint(address to, uint amount) public {
        _mint(to, amount);
    }
}