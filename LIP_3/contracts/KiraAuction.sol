pragma solidity 0.6.2;

import 'openzeppelin-solidity/contracts/token/ERC20/IERC20.sol';
import 'openzeppelin-solidity/contracts/access/Ownable.sol';
import 'openzeppelin-solidity/contracts/math/SafeMath.sol';

/**
 * @title KiraAuction
 * @dev Liquidity Auction Contract for the final round of the KEX token distribution.
 *
 * The Liquidity Auction works in the similar fashion to the Polkadot Reverse Dutch auction
 * with the difference that in case of oversubscription all tokens that overflowed the hard
 * cap would be used to add liquidity to the uniswap or as MM war chest in case of listing
 * to support price on the market.
 *
 * Reverse Dutch auction starts with a very very high initial valuation that cannot possibly
 * be fulfilled and decreases towards predefined valuation at predefined rate. Auction ends
 * instantly if value of assets deposited is greater or equals to the valuation, or if auction
 * times out.
 */

contract KiraAuction is Ownable {
    using SafeMath for uint256;

    /* 
        Configurable
        P1, P2, T1, T2, Auction Start, Tx rate limiting, Tx size per time limit, whitelist
    */

    address payable public wallet;

    uint256 public startTime = 0;
    uint256 private P1;
    uint256 private P2;
    uint256 private T1;
    uint256 private T2;
    uint256 private MAX_WEI = 0 ether;
    uint256 private INTERVAL_LIMIT = 0;

    struct UserInfo {
        bool whitelisted;
        uint256 claimed_wei;
        uint256 last_deposit_time;
    }

    mapping(address => UserInfo) private customers;

    IERC20 private kiraToken;

    uint256 private totalWeiAmount = 0;
    uint256 private latestPrice = 0;

    // Events
    event AuctionConfigured(uint256 _startTime);
    event AddedToWhitelist(address addr);
    event ProcessedBuy(address addr, uint256 amount);
    event ClaimedTokens(address addr, uint256 amount);
    event WithdrawedFunds(address _wallet, uint256 amount);

    // MODIFIERS

    modifier onlyInProgress() {
        require(startTime != 0, 'KiraAuction: start time is not configured yet. So not in progress.');
        require((startTime <= now) && (now <= startTime + T1 + T2), 'KiraAuction: it is out of processing period.');
        uint256 cap = _getCurrentCap();
        require(cap >= totalWeiAmount, 'KiraAuction: overflows the cap, so it is ended');
        _;
    }

    modifier onlyBeforeAuction() {
        require(startTime == 0 || (now < startTime), 'KiraAuction: should be before auction starts');
        _;
    }

    modifier onlyAfterAuction() {
        uint256 cap = _getCurrentCap();
        require(startTime != 0 && ((startTime + T1 + T2 < now) || (cap < totalWeiAmount)), 'KiraAuction: should be after auction ends');
        _;
    }

    // Constructor

    constructor(IERC20 _kiraToken) public {
        kiraToken = _kiraToken;
        wallet = msg.sender;
    }

    // External Views

    function getCurrentAuctionPrice() external view returns (uint256) {
        return _getCurrentAuctionPrice();
    }

    function totalDeposited() external view returns (uint256) {
        return totalWeiAmount;
    }

    function whitelisted(address addr) external view returns (bool) {
        return customers[addr].whitelisted;
    }

    function getCustomerInfo(address addr)
        external
        view
        returns (
            bool,
            uint256,
            uint256
        )
    {
        return (customers[addr].whitelisted, customers[addr].claimed_wei, customers[addr].last_deposit_time);
    }

    function getAuctionConfigInfo()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (startTime, P1, P2, T1, T2, MAX_WEI, INTERVAL_LIMIT);
    }

    function getWalletAddress() external view returns (address) {
        return wallet;
    }

    function getLatestPrice() external view returns (uint256) {
        return latestPrice;
    }

    // Internal Views

    function _getCurrentAuctionPrice() internal view returns (uint256) {
        /*     ^
            P1 |        *
               |        '*
               |        ' *
               |        '  *
            P2 |        '   *
               |        '   '   *
               |        '   '       *
               |        '   '           *
               |        '   '               *
               |        '   '                   *
               |--------|---|-----------------------|----------> Timeline
                          T1           T2
        */

        uint256 price = 0;

        if ((startTime <= now) && (now < startTime + T1)) {
            // Slope 1
            // y = p1 - (x * (p1 - p2) / t1)

            uint256 x = now - startTime;
            uint256 delta = x.mul(P1 - P2).div(T1);

            price = P1.sub(delta);
        } else if ((startTime + T1 <= now) && (now <= startTime + T1 + T2)) {
            // Slope 2
            // y = p2 - (x * p2 / t2)
            uint256 x = now - startTime - T1;
            uint256 delta = x.mul(P2).div(T2);

            price = P2.sub(delta);
        }

        return price;
    }

    function _getCurrentCap() internal view returns (uint256) {
        uint256 price = _getCurrentAuctionPrice();
        uint256 numberOfTokens = kiraToken.balanceOf(address(this));
        uint256 cap = price.mul(numberOfTokens);

        return cap;
    }

    // Auction Config Method only for owner. only before auction

    function setWallet(address payable _wallet) external onlyOwner onlyBeforeAuction {
        wallet = _wallet;
    }

    function configAuction(
        uint256 _startTime,
        uint256 _p1,
        uint256 _p2,
        uint256 _t1,
        uint256 _t2,
        uint256 _txIntervalLimit,
        uint256 _txMaxEthAmount
    ) external onlyOwner onlyBeforeAuction {
        require(_startTime > now, 'KiraAuction: start time should be greater than now');
        require((_p1 > _p2) && (_p2 >= 0), 'KiraAuction: price should go decreasing.');
        require(_t1 < _t2, 'KiraAuction: the first slope should have faster decreasing rate.');
        require((_t1 > 0) && (_t2 > 0), 'KiraAuction: the period of each slope should be greater than zero.');
        require(_txIntervalLimit >= 0, 'KiraAuction: the interval rate per tx should be valid');
        require(_txMaxEthAmount > 0, 'KiraAuction: the maximum amount per tx should be valid');

        startTime = _startTime;
        P1 = _p1 * 1 ether;
        P2 = _p2 * 1 ether;
        T1 = _t1;
        T2 = _t2;
        INTERVAL_LIMIT = _txIntervalLimit;
        MAX_WEI = _txMaxEthAmount * 1 ether;

        emit AuctionConfigured(startTime);
    }

    function whitelist(address addr) external onlyOwner onlyBeforeAuction {
        require(addr != address(0), 'KiraAuction: not be able to whitelist address(0).');
        customers[addr].whitelisted = true;

        emit AddedToWhitelist(addr);
    }

    // only in progress

    receive() external payable {
        _processBuy(msg.sender, msg.value);
    }

    function _processBuy(address beneficiary, uint256 weiAmount) private onlyInProgress {
        require(beneficiary != address(0), 'KiraAuction: Not zero address');
        require(beneficiary != owner(), 'KiraAuction: Not owner');
        require(weiAmount > 0, 'KiraAuction: That is not enough.');
        require(weiAmount <= MAX_WEI, 'KiraAuction: That is too much.');
        require(customers[beneficiary].whitelisted, "KiraAuction: You're not whitelisted, wait a moment.");
        require(now - customers[beneficiary].last_deposit_time >= INTERVAL_LIMIT, 'KiraAuction: it exceeds the tx rate limit');

        uint256 cap = _getCurrentCap();

        require(totalWeiAmount.add(weiAmount) < cap, 'KiraAuction: You contribution overflows the hard cap!');

        customers[beneficiary].claimed_wei = customers[beneficiary].claimed_wei.add(weiAmount);
        customers[beneficiary].last_deposit_time = now;

        totalWeiAmount = totalWeiAmount.add(weiAmount);

        emit ProcessedBuy(beneficiary, weiAmount);

        uint256 numberOfTokens = kiraToken.balanceOf(address(this));
        latestPrice = totalWeiAmount.div(numberOfTokens);
    }

    // only after auction

    function claimTokens() external onlyAfterAuction {
        UserInfo memory customer = customers[msg.sender];
        require(customer.whitelisted && customer.claimed_wei > 0, 'KiraAuction: you did not contribute.');

        uint256 amountToClaim = customer.claimed_wei.div(latestPrice);

        kiraToken.transfer(msg.sender, amountToClaim);

        emit ClaimedTokens(msg.sender, amountToClaim);
    }

    function withdrawFunds() external onlyOwner onlyAfterAuction {
        uint256 balance = address(this).balance;
        require(balance > 0, 'KiraAuction: nothing left to withdraw');

        wallet.transfer(balance);

        emit WithdrawedFunds(wallet, balance);
    }
}
