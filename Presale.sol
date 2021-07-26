// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "./Constants.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeFactory.sol";

interface TIUFPool {
  function depositTo(uint256 _pid, uint256 _amount, address _to) external;
}

library PresaleConstants {
  // presale
  uint constant PRESALE_START_TIME = 1627776000;
  uint constant PRESALE_END_TIME = 1628208000;
  uint256 constant PRESALE_EXCHANGE_RATE = 200000;      // 1 BNB ~ 200000 TIU
  uint256 constant PRESALE_MIN_AMOUNT = 1e18;         // 1 BNB
  uint256 constant PRESALE_MAX_AMOUNT = 10e18;         // 10 BNB
  uint256 constant PRESALE_WHITELIST_AMOUNT = 500e18;  // 500 BNB
}

contract TIUPresale is Ownable {
  using SafeMath for uint256;
  using SafeBEP20 for IBEP20;

  IPancakeFactory private factory = IPancakeFactory(Constants.PANCAKE_FACTORY);
  IPancakeRouter02 private router = IPancakeRouter02(Constants.PANCAKE_ROUTER);

  uint public startTime;
  uint public endTime;

  uint256 public exchangeRate;
  uint256 public minAmount;
  uint256 public maxAmount;
  uint256 public whitelistSaleTotal;

  address public token;

  address public masterChef;
  address public stakingRewards;

  uint public totalBalance;
  uint public totalFlipBalance;

  mapping (address => uint) private balance;
  mapping (address => bool) private whitelist;
  address[] public users;

  event Deposited(address indexed account, uint256 indexed amount);
  event Whitelisted(address indexed account, bool indexed allow);

  constructor() public {
    startTime = PresaleConstants.PRESALE_START_TIME;
    endTime = PresaleConstants.PRESALE_END_TIME;

    exchangeRate = PresaleConstants.PRESALE_EXCHANGE_RATE;

    minAmount = PresaleConstants.PRESALE_MIN_AMOUNT.mul(PresaleConstants.PRESALE_EXCHANGE_RATE);
    maxAmount = PresaleConstants.PRESALE_MAX_AMOUNT.mul(PresaleConstants.PRESALE_EXCHANGE_RATE);

    whitelistSaleTotal = PresaleConstants.PRESALE_WHITELIST_AMOUNT.mul(PresaleConstants.PRESALE_EXCHANGE_RATE);

    // add whitelist addresses
    configWhitelist(0xFdD6c8868983f60d635161A20c9A46C002Af7B09, true);
  }

  receive() payable external {}

  function balanceOf(address account) public view returns(uint) {
    return balance[account];
  }

  function flipToken() public view returns(address) {
    return factory.getPair(token, router.WETH());
  }

  function usersLength() public view returns (uint256) {
    return users.length;
  }

  // return available amount for deposit in BNB
  function availableOf(address account) public view returns (uint256) {
    uint256 available;

    //Sale time
    if (now < startTime || now > endTime) {
      return 0;
    }

    //Only whitelisted users
    if(!whitelist[account]) {
      return 0;
    }


    available = maxAmount.sub(balance[account]);

    if (available > whitelistSaleTotal) {
      available = whitelistSaleTotal;
    }

    return available.div(exchangeRate);
  }

  function deposit() public payable {
    address user = msg.sender;
    uint256 amount = msg.value.mul(exchangeRate); // convert BNB to TIU amount

    require(now >= startTime || now <= endTime, "!open");

    uint256 available = availableOf(user).mul(exchangeRate);
    require(amount <= available, "!available");
    require(amount >= minAmount, "!minimum");

    if (!findUser(user)) {
      users.push(user);
    }

    balance[user] = balance[user].add(amount);
    totalBalance = totalBalance.add(amount);
    whitelistSaleTotal = whitelistSaleTotal.sub(amount);

    emit Deposited(user, amount);
  }

  function findUser(address user) private view returns (bool) {
    for (uint i = 0; i < users.length; i++) {
      if (users[i] == user) {
        return true;
      }
    }

    return false;
  }

  // init and add liquidity
  function initialize(address _token, address _masterChef, address _rewards) public onlyOwner {
    token = _token;
    masterChef = _masterChef;
    stakingRewards = _rewards;

    require(IBEP20(token).balanceOf(address(this)) >= totalBalance, "less token");

    uint256 tokenAmount = totalBalance.div(2);
    uint256 amount = address(this).balance;

    IBEP20(token).safeApprove(address(router), 0);
    IBEP20(token).safeApprove(address(router), tokenAmount);
    router.addLiquidityETH{value: amount.div(2)}(token, tokenAmount, 0, 0, address(this), block.timestamp);

    address lp = flipToken();
    totalFlipBalance = IBEP20(lp).balanceOf(address(this));
  }

  function distributeTokens(uint256 _pid) public onlyOwner {
    require(stakingRewards != address(0), 'not set stakingRewards');

    IBEP20(token).safeApprove(stakingRewards, 0);
    IBEP20(token).safeApprove(stakingRewards, totalBalance.div(2));

    for(uint i=0; i<usersLength(); i++) {
      address user = users[i];
      uint share = shareOf(user);

      _distributeToken(user, share, _pid);

      delete balance[user];
    }
  }


  function _distributeToken(address user, uint share, uint pid) private {
    uint remaining = IBEP20(token).balanceOf(address(this));
    uint amount = totalBalance.div(2).mul(share).div(1e18);
    if (amount == 0) return;

    if (remaining < amount) {
      amount = remaining;
    }

    IMRFPool(stakingRewards).depositTo(pid, amount, user);
  }

  function shareOf(address _user) private view returns(uint256) {
    return balance[_user].mul(1e18).div(totalBalance);
  }

  function configWhitelist(address user, bool allow) public onlyOwner {
    whitelist[user] = allow;

    emit Whitelisted(user, allow);
  }

  // config the presale rate
  function configMoney(
    uint256 _exchangeRate,
    uint256 _minBNBAmount,
    uint256 _maxBNBAmount,
    uint256 _whitelistBNBTotal
  ) public onlyOwner {
    exchangeRate = _exchangeRate;

    minAmount = _minBNBAmount.mul(_exchangeRate);
    maxAmount = _maxBNBAmount.mul(_exchangeRate);

    whitelistSaleTotal = _whitelistBNBTotal.mul(_exchangeRate);
  }

  // config the presale timeline
  function configTime(
    uint _startTime,
    uint _endTime
  ) public onlyOwner {
    startTime = _startTime;
    endTime = _endTime;
  }

  // backup function for emergency situation
  function setAddress(address _token, address _masterChef, address _rewards) public onlyOwner {
    token = _token;
    masterChef = _masterChef;
    stakingRewards = _rewards;
  }

  function finalize() public onlyOwner {
    payable(owner()).transfer(address(this).balance);
  }
}
