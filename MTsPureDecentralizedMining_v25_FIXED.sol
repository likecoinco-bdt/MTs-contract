// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title  MTsPureDecentralizedMining — v25.0 "Autonomous Edition"
 * @notice Base Mainnet · 30-Year Halving · Dual Mining
 *
 * ════════════════════════════════════════════════════════════
 *  DESIGN GOAL: Permanently autonomous on-chain institution.
 *
 *  This version is built to operate for decades without any
 *  human intervention.  After deployment, initialization, and
 *  testing, the deployer calls renounceOwnership() exactly once.
 *  From that point forward there is NO privileged actor of any
 *  kind — not the deployer, not anyone.
 *
 *  v25 REMOVALS vs v24.1 (by design, not oversight):
 *
 *  [R1] Pausable removed entirely.
 *       pause() / unpause() / whenNotPaused deleted.
 *       The protocol can never be halted by anyone, including
 *       its creator.  Users can always stake, unstake, claim,
 *       and emergency-exit.
 *
 *  [R2] recoverERC20() removed.
 *       No one can ever extract any ERC20 token sent to this
 *       contract, by accident or otherwise.
 *
 *  [R3] recoverETH() removed.
 *       receive() still rejects ETH unconditionally, so funds
 *       can never become permanently locked here in the first
 *       place.
 *
 *  [R4] recoverStuckNFT() removed, along with
 *       _crystallizeAccount() and the NFTRecovered event.
 *       No one — including the original deployer — can ever
 *       seize, transfer, or unstake another user's NFT.
 *       emergencyUnstakeNFT(), controlled solely by the staker,
 *       is the only exit path.
 *
 *  [R5] syncDonatedTokens() removed, along with
 *       getUnsyncedBalance(), DonationSynced, and
 *       UnsyncedBalanceWarning.
 *       There is no "activation" step for donated tokens and
 *       therefore no privileged party who could time or gate
 *       that activation. See the PERMANENT DONATION NOTE below.
 *
 *  [R6] No upgrade mechanism of any kind exists, was ever
 *       planned, or is structurally possible (no proxy, no
 *       delegatecall, no admin-settable implementation slot).
 *
 *  The ONLY function that ever requires onlyOwner is
 *  renounceOwnership() itself — and after it is called once,
 *  owner() permanently returns address(0), so even that
 *  capability disappears.
 * ════════════════════════════════════════════════════════════
 *
 *  PRESERVED ECONOMIC GUARANTEES (immutable, hardcoded):
 *
 *  - POOL_SHARE_BPS / OWNER_SHARE_BPS = 8000 / 2000 (80% / 20%)
 *    on every NFT mint, enforced in mintAndAutoStake().
 *    PROFIT_RECEIVER is an immutable constant address — it
 *    cannot be changed by anyone, ever.
 *
 *  - 30-year, 29-step halving schedule via
 *    _getCappedEmission() / INITIAL_EMISSION_RATE / HALVING_PERIOD.
 *    Identical math to v24.1 — no changes to emission logic.
 *
 *  - NFT mining (mintAndAutoStake / unstakeNFT /
 *    stakeExistingNFT / emergencyUnstakeNFT) — unchanged.
 *
 *  - LP mining (stakeLP / unstakeLP / emergencyWithdrawLP) —
 *    unchanged.
 *
 *  - claimRewards() — unchanged pure state-based accounting
 *    from v24.1 [G1/H2].
 *
 *  - fundRewards() — PERMISSIONLESS. Anyone may top up the
 *    reward reserve at any time; this is not an admin function
 *    and is preserved exactly as in prior versions.
 * ════════════════════════════════════════════════════════════
 *
 *  PERMANENT DONATION NOTE (replaces v23/v24 sync mechanism):
 *
 *  If MTS tokens are sent directly to this contract (bypassing
 *  fundRewards() / mintAndAutoStake()), mtsToken.balanceOf(this)
 *  will permanently exceed accountedBalance by that amount.
 *  Those tokens are NOT lost and NOT claimable by any third
 *  party — they simply sit in the contract's real balance and
 *  are excluded from rewardReserve / emission math forever,
 *  since there is intentionally no sync function in this
 *  edition. Anyone wishing to direct extra tokens into the
 *  reward schedule should call fundRewards(), not transfer
 *  directly. This is documented here so that, decades from now,
 *  anyone reading the verified source understands this is
 *  intentional and permanent — not a bug requiring an admin fix.
 * ════════════════════════════════════════════════════════════
 */
contract MTsPureDecentralizedMining is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────
    // IMMUTABLES
    // ─────────────────────────────────────────────────────────
    IERC20  public immutable mtsToken;
    IERC20  public immutable uniswapLPToken;
    address public constant  PROFIT_RECEIVER    = 0xbcF11cc87B17aB07A4E1163e26e82B5a003E43bc;
    uint256 public immutable deploymentTime;
    uint256 public immutable POWER_PER_LP_TOKEN;
    uint256 private immutable lpMultiplier;

    // ─────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────
    uint256 public constant BASIC_MINT_PRICE    =  5_000 * 1e18;
    uint256 public constant ADVANCED_MINT_PRICE = 10_000 * 1e18;
    uint256 public constant ELITE_MINT_PRICE    = 25_000 * 1e18;

    uint256 public constant POOL_SHARE_BPS  = 8000;
    uint256 public constant OWNER_SHARE_BPS = 2000;

    uint256 public constant BASIC_POWER    = 10000;
    uint256 public constant ADVANCED_POWER = 25000;
    uint256 public constant ELITE_POWER    = 50000;

    uint256 public constant INITIAL_EMISSION_RATE = 57870370370370;
    uint256 public constant HALVING_PERIOD        = 365 days;

    // ─────────────────────────────────────────────────────────
    // NFT STATE
    // ─────────────────────────────────────────────────────────
    uint256 private _nextTokenId = 1;

    mapping(uint256 => uint256) public nftHashPower;
    mapping(uint256 => address) public nftStaker;
    mapping(uint256 => uint8)   public nftTier;

    // ─────────────────────────────────────────────────────────
    // LP STATE
    // ─────────────────────────────────────────────────────────
    mapping(address => uint256) public stakedLPAmount;
    mapping(address => uint256) public lpHashPower;

    // ─────────────────────────────────────────────────────────
    // REWARD ACCOUNTING
    // ─────────────────────────────────────────────────────────
    uint256 public totalGlobalHashPower;
    uint256 public rewardPerHashPointStored;
    uint256 public lastUpdateTime;
    uint256 public rewardReserve;
    uint256 public rewardRemainder;
    uint256 public totalCrystallizedRewards;

    /**
     * @dev Internal balance tracker — single source of truth for
     *      all emission math, pool-health, and claim logic.
     *
     *      IN  → accountedBalance += amount  (fundRewards, mintAndAutoStake)
     *      OUT → accountedBalance -= amount  (claimRewards)
     *
     *      Direct token transfers (donations) increase
     *      mtsToken.balanceOf(this) without touching this
     *      variable. See PERMANENT DONATION NOTE above — this
     *      is intentional and permanent in this autonomous
     *      edition; there is no sync mechanism.
     *
     *      Invariant (soft): accountedBalance <= mtsToken.balanceOf(this)
     */
    uint256 public accountedBalance;

    mapping(address => uint256) public userTotalHashPower;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // ─────────────────────────────────────────────────────────
    // METADATA  (immutable strings, set once at construction)
    // ─────────────────────────────────────────────────────────
    string public basicURI;
    string public advancedURI;
    string public eliteURI;

    // ─────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────
    event NFTMintedAndStaked      (address indexed user, uint256 tokenId, uint8 tier, uint256 hashPower);
    event NFTUnstaked             (address indexed user, uint256 tokenId);
    event NFTRestaked             (address indexed user, uint256 tokenId, uint256 hashPower);
    event NFTEmergencyUnstaked    (address indexed user, uint256 tokenId, uint256 powerRemoved, uint256 rewardsForfeited);
    event LPStaked                (address indexed user, uint256 amount, uint256 powerGained);
    event LPUnstaked              (address indexed user, uint256 amount, uint256 powerLost);
    event LPEmergencyWithdrawn    (address indexed user, uint256 amount, uint256 rewardsForfeited);
    event RewardClaimed           (address indexed user, uint256 amount);
    event RewardDeferred          (address indexed user, uint256 deferredAmount);
    event PoolFunded              (address indexed funder, uint256 amount);
    event ProtocolDecentralized   (address indexed oldOwner);

    // ─────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────
    constructor(
        string  memory _name,
        string  memory _symbol,
        string  memory _basicURI,
        string  memory _advancedURI,
        string  memory _eliteURI,
        address        _mtsToken,
        address        _uniswapLPToken,
        address        _initialOwner,
        uint256        _powerPerLPToken
    ) ERC721(_name, _symbol) Ownable(_initialOwner) {

        require(POOL_SHARE_BPS + OWNER_SHARE_BPS == 10000, "BPS must sum to 10000");
        require(_mtsToken        != address(0), "Zero MTS token");
        require(_uniswapLPToken  != address(0), "Zero LP token");
        require(_initialOwner    != address(0), "Zero owner");
        require(_powerPerLPToken >  0,          "Power per LP must be > 0");
        require(bytes(_basicURI).length    > 0, "Empty basic URI");
        require(bytes(_advancedURI).length > 0, "Empty advanced URI");
        require(bytes(_eliteURI).length    > 0, "Empty elite URI");

        // LP Pair Verification
        {
            address WETH = 0x4200000000000000000000000000000000000006;
            address t0; address t1;
            try IUniswapV2Pair(_uniswapLPToken).token0() returns (address _t0) { t0 = _t0; }
            catch { revert("Invalid MTS/WETH LP Pair"); }
            try IUniswapV2Pair(_uniswapLPToken).token1() returns (address _t1) { t1 = _t1; }
            catch { revert("Invalid MTS/WETH LP Pair"); }
            require(
                (t0 == _mtsToken || t1 == _mtsToken) &&
                (t0 == WETH      || t1 == WETH),
                "Invalid MTS/WETH LP Pair"
            );
        }

        mtsToken           = IERC20(_mtsToken);
        uniswapLPToken     = IERC20(_uniswapLPToken);
        POWER_PER_LP_TOKEN = _powerPerLPToken;
        basicURI           = _basicURI;
        advancedURI        = _advancedURI;
        eliteURI           = _eliteURI;

        uint8 lpDecimals;
        try IERC20Metadata(_uniswapLPToken).decimals() returns (uint8 d) { lpDecimals = d; }
        catch { lpDecimals = 18; }
        require(lpDecimals <= 18, "Unsupported LP decimals");
        lpMultiplier = 10 ** lpDecimals;

        deploymentTime = block.timestamp;
        lastUpdateTime = block.timestamp;
    }

    /**
     * @dev ETH is never needed by this protocol and there is no
     *      way to recover it (recoverETH was removed in v25 — see
     *      [R3]).  Reject all incoming ETH unconditionally so funds
     *      can never become permanently locked here.
     */
    receive() external payable { revert("ETH not accepted"); }

    // ═════════════════════════════════════════════════════════
    // UNIFIED EMISSION HELPER  (unchanged from v24.1 [E1/F4])
    // ═════════════════════════════════════════════════════════

    function _getCappedEmission(
        uint256 from,
        uint256 to,
        uint256 reserveSnap,
        uint256 crystalSnap,
        uint256 balSnap
    ) internal view returns (uint256 emitted) {

        uint256 finalEpochStart = deploymentTime + 29 * HALVING_PERIOD;
        if (from >= finalEpochStart) return 0;
        if (to   >  finalEpochStart) to = finalEpochStart;
        if (to   <= from)            return 0;

        uint256 eStart = (from - deploymentTime) / HALVING_PERIOD;
        uint256 eEnd   = (to   - deploymentTime) / HALVING_PERIOD;
        if (eStart > 28) return 0;
        if (eEnd   > 28) eEnd = 28;

        emitted = 0;
        for (uint256 e = eStart; e <= eEnd; e++) {
            uint256 segS = deploymentTime + e       * HALVING_PERIOD;
            uint256 segE = deploymentTime + (e + 1) * HALVING_PERIOD;
            uint256 oS   = from > segS ? from : segS;
            uint256 oE   = to   < segE ? to   : segE;
            if (oE <= oS) continue;
            emitted += (oE - oS) * (INITIAL_EMISSION_RATE >> e);
        }

        if (emitted > reserveSnap) emitted = reserveSnap;

        uint256 surplus = balSnap > crystalSnap ? balSnap - crystalSnap : 0;
        if (emitted > surplus) emitted = surplus;
    }

    // ═════════════════════════════════════════════════════════
    // GLOBAL ACCUMULATOR
    // ═════════════════════════════════════════════════════════

    function _updateGlobalReward() internal {
        if (block.timestamp <= lastUpdateTime) return;
        uint256 gp = totalGlobalHashPower;
        if (gp == 0 || rewardReserve == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        uint256 emitted = _getCappedEmission(
            lastUpdateTime,
            block.timestamp,
            rewardReserve,
            totalCrystallizedRewards,
            accountedBalance
        );

        if (emitted > 0) {
            uint256 totalRA          = (emitted * 1e18) + rewardRemainder;
            rewardPerHashPointStored += totalRA / gp;
            rewardRemainder           = totalRA % gp;
            rewardReserve            -= emitted;
        }
        lastUpdateTime = block.timestamp;
    }

    // ═════════════════════════════════════════════════════════
    // MODIFIER
    // ═════════════════════════════════════════════════════════
    modifier updateReward(address account) {
        _updateGlobalReward();
        if (account != address(0)) {
            uint256 oldReward = rewards[account];
            uint256 newEarned = earned(account);
            assert(newEarned >= oldReward);
            if (newEarned > oldReward) {
                totalCrystallizedRewards += (newEarned - oldReward);
            }
            rewards[account]                = newEarned;
            userRewardPerTokenPaid[account] = rewardPerHashPointStored;
        }
        _;
    }

    // ═════════════════════════════════════════════════════════
    // VIEW: REWARD
    // ═════════════════════════════════════════════════════════

    function rewardPerHashPoint() public view returns (uint256) {
        uint256 gp = totalGlobalHashPower;
        if (
            block.timestamp == lastUpdateTime ||
            gp              == 0              ||
            rewardReserve   == 0
        ) return rewardPerHashPointStored;

        uint256 emitted = _getCappedEmission(
            lastUpdateTime,
            block.timestamp,
            rewardReserve,
            totalCrystallizedRewards,
            accountedBalance
        );
        uint256 totalRA = (emitted * 1e18) + rewardRemainder;
        return rewardPerHashPointStored + (totalRA / gp);
    }

    function earned(address account) public view returns (uint256) {
        return (
            userTotalHashPower[account] *
            (rewardPerHashPoint() - userRewardPerTokenPaid[account]) / 1e18
        ) + rewards[account];
    }

    function totalUncrystallizedRewards() public view returns (uint256) {
        uint256 rpDelta = rewardPerHashPoint() - rewardPerHashPointStored;
        return (totalGlobalHashPower * rpDelta) / 1e18;
    }

    function totalLiability() public view returns (uint256) {
        return rewardReserve + totalCrystallizedRewards + totalUncrystallizedRewards();
    }

    function getCurrentEmissionRate() public view returns (uint256) {
        uint256 halvingCount = (block.timestamp - deploymentTime) / HALVING_PERIOD;
        if (halvingCount >= 29) return 0;
        return INITIAL_EMISSION_RATE >> halvingCount;
    }

    // ═════════════════════════════════════════════════════════
    // INTERNAL: FULL REWARD FORFEIT  (unchanged from v24.1 [F1/F2])
    // ═════════════════════════════════════════════════════════

    /**
     * @dev Must be called AFTER _updateGlobalReward() and BEFORE
     *      hash power is removed so earned() is still correct.
     *      Forfeits the user's entire pending reward; returns the
     *      forfeited amount for event emission.
     */
    function _forfeitFullRewards(address account)
        internal
        returns (uint256 forfeited)
    {
        uint256 fullReward = earned(account);

        if (fullReward > 0) {
            uint256 stored = rewards[account];
            if (fullReward > stored) {
                totalCrystallizedRewards += (fullReward - stored);
            }
            rewards[account] = 0;
            if (totalCrystallizedRewards >= fullReward) {
                totalCrystallizedRewards -= fullReward;
            } else {
                totalCrystallizedRewards  = 0;
            }
        }

        userRewardPerTokenPaid[account] = rewardPerHashPointStored;
        return fullReward;
    }

    // ═════════════════════════════════════════════════════════
    // LP STAKING
    // ═════════════════════════════════════════════════════════
    function stakeLP(uint256 amount)
        external nonReentrant updateReward(msg.sender)
    {
        require(amount > 0, "Cannot stake 0 LP");

        uint256 balBefore    = uniswapLPToken.balanceOf(address(this));
        uniswapLPToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = uniswapLPToken.balanceOf(address(this)) - balBefore;

        uint256 powerGained = (actualAmount * POWER_PER_LP_TOKEN) / lpMultiplier;
        require(powerGained > 0, "Deposit too small for power conversion");

        stakedLPAmount[msg.sender]     += actualAmount;
        lpHashPower[msg.sender]        += powerGained;
        userTotalHashPower[msg.sender] += powerGained;
        totalGlobalHashPower           += powerGained;

        emit LPStaked(msg.sender, actualAmount, powerGained);
    }

    function unstakeLP(uint256 amount)
        external nonReentrant updateReward(msg.sender)
    {
        require(amount > 0, "Cannot unstake 0 LP");
        uint256 lpBal = stakedLPAmount[msg.sender];
        require(lpBal >= amount, "LP balance too low");

        uint256 powerLost = (amount == lpBal)
            ? lpHashPower[msg.sender]
            : (lpHashPower[msg.sender] * amount) / lpBal;

        require(lpHashPower[msg.sender]        >= powerLost, "LP power underflow");
        require(userTotalHashPower[msg.sender] >= powerLost, "User hash underflow");
        require(totalGlobalHashPower           >= powerLost, "Global hash underflow");

        stakedLPAmount[msg.sender]     -= amount;
        lpHashPower[msg.sender]        -= powerLost;
        userTotalHashPower[msg.sender] -= powerLost;
        totalGlobalHashPower           -= powerLost;

        // Dust cleanup: intentional. On full withdrawal, residual
        // lpHashPower from integer-division rounding is zeroed.
        if (stakedLPAmount[msg.sender] == 0 && lpHashPower[msg.sender] > 0) {
            uint256 dust = lpHashPower[msg.sender];
            lpHashPower[msg.sender] = 0;
            if (userTotalHashPower[msg.sender] >= dust) userTotalHashPower[msg.sender] -= dust;
            if (totalGlobalHashPower           >= dust) totalGlobalHashPower           -= dust;
        }

        uniswapLPToken.safeTransfer(msg.sender, amount);
        emit LPUnstaked(msg.sender, amount, powerLost);
    }

    // ═════════════════════════════════════════════════════════
    // EMERGENCY LP WITHDRAW  (unchanged from v24.1 [F2/E3])
    // ═════════════════════════════════════════════════════════

    function emergencyWithdrawLP() external nonReentrant {
        uint256 amount = stakedLPAmount[msg.sender];
        uint256 power  = lpHashPower[msg.sender];
        require(amount > 0, "No LP staked");

        _updateGlobalReward();

        uint256 forfeited = _forfeitFullRewards(msg.sender);

        stakedLPAmount[msg.sender] = 0;
        lpHashPower[msg.sender]    = 0;

        if (userTotalHashPower[msg.sender] >= power) {
            userTotalHashPower[msg.sender] -= power;
        } else {
            userTotalHashPower[msg.sender]  = 0;
        }
        if (totalGlobalHashPower >= power) {
            totalGlobalHashPower -= power;
        } else {
            totalGlobalHashPower  = 0;
        }

        uniswapLPToken.safeTransfer(msg.sender, amount);
        emit LPEmergencyWithdrawn(msg.sender, amount, forfeited);
    }

    // ═════════════════════════════════════════════════════════
    // NFT MINTING & STAKING
    // ═════════════════════════════════════════════════════════
    function mintAndAutoStake(uint8 tier)
        external nonReentrant updateReward(msg.sender)
        returns (uint256)
    {
        require(tier >= 1 && tier <= 3, "Invalid tier: use 1, 2, or 3");

        uint256 mintPrice;
        uint256 power;
        if      (tier == 1) { mintPrice = BASIC_MINT_PRICE;    power = BASIC_POWER;    }
        else if (tier == 2) { mintPrice = ADVANCED_MINT_PRICE; power = ADVANCED_POWER; }
        else                { mintPrice = ELITE_MINT_PRICE;    power = ELITE_POWER;    }

        // Immutable 80/20 split — PROFIT_RECEIVER is a hardcoded constant
        uint256 poolAmount  = (mintPrice * POOL_SHARE_BPS)  / 10000;
        uint256 ownerAmount = (mintPrice * OWNER_SHARE_BPS) / 10000;

        uint256 balBefore        = mtsToken.balanceOf(address(this));
        mtsToken.safeTransferFrom(msg.sender, address(this), poolAmount);
        uint256 actualPoolAmount = mtsToken.balanceOf(address(this)) - balBefore;
        rewardReserve    += actualPoolAmount;
        accountedBalance += actualPoolAmount;

        mtsToken.safeTransferFrom(msg.sender, PROFIT_RECEIVER, ownerAmount);

        uint256 tokenId = _nextTokenId;
        unchecked { _nextTokenId++; }
        _safeMint(msg.sender, tokenId);

        nftTier[tokenId]               = tier;
        nftHashPower[tokenId]          = power;
        nftStaker[tokenId]             = msg.sender;
        userTotalHashPower[msg.sender] += power;
        totalGlobalHashPower           += power;

        emit NFTMintedAndStaked(msg.sender, tokenId, tier, power);
        return tokenId;
    }

    function unstakeNFT(uint256 tokenId)
        external nonReentrant updateReward(msg.sender)
    {
        require(nftStaker[tokenId] == msg.sender, "Not the staker");

        uint256 power = nftHashPower[tokenId];
        require(userTotalHashPower[msg.sender] >= power, "User hash underflow");
        require(totalGlobalHashPower           >= power, "Global hash underflow");

        userTotalHashPower[msg.sender] -= power;
        totalGlobalHashPower           -= power;
        nftStaker[tokenId]              = address(0);

        emit NFTUnstaked(msg.sender, tokenId);
    }

    function stakeExistingNFT(uint256 tokenId)
        external nonReentrant updateReward(msg.sender)
    {
        require(ownerOf(tokenId)   == msg.sender, "Not the NFT owner");
        require(nftStaker[tokenId] == address(0), "Already staked");
        uint256 power = nftHashPower[tokenId];
        require(power > 0, "NFT has no mining power");

        nftStaker[tokenId]              = msg.sender;
        userTotalHashPower[msg.sender] += power;
        totalGlobalHashPower           += power;

        emit NFTRestaked(msg.sender, tokenId, power);
    }

    // ═════════════════════════════════════════════════════════
    // EMERGENCY NFT UNSTAKE  (unchanged from v24.1 [F1/E5])
    //
    // This is the ONLY exit path for a staked NFT, and it is
    // controlled exclusively by the staker themselves. No third
    // party — including the original deployer — has any way to
    // unstake, seize, or move another user's NFT.
    // ═════════════════════════════════════════════════════════

    function emergencyUnstakeNFT(uint256 tokenId) external nonReentrant {
        require(nftStaker[tokenId] == msg.sender, "Not the staker");
        require(ownerOf(tokenId)   == msg.sender, "Not NFT owner");

        uint256 power = nftHashPower[tokenId];

        _updateGlobalReward();

        uint256 forfeited = _forfeitFullRewards(msg.sender);

        nftStaker[tokenId] = address(0);

        if (userTotalHashPower[msg.sender] >= power) {
            userTotalHashPower[msg.sender] -= power;
        } else {
            userTotalHashPower[msg.sender]  = 0;
        }
        if (totalGlobalHashPower >= power) {
            totalGlobalHashPower -= power;
        } else {
            totalGlobalHashPower  = 0;
        }

        emit NFTEmergencyUnstaked(msg.sender, tokenId, power, forfeited);
    }

    // ═════════════════════════════════════════════════════════
    // CLAIM REWARDS  (unchanged from v24.1 [G1/H2])
    // ═════════════════════════════════════════════════════════

    /**
     * @dev Pure state-based accounting — no live balanceOf() calls.
     *      accountedBalance is the single source of truth for solvency
     *      and transfer amounts, consistent with emission math.
     */
    function claimRewards()
        external nonReentrant updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to claim");

        uint256 payableAmount = reward > accountedBalance ? accountedBalance : reward;
        require(payableAmount > 0, "Pool is empty - try again after refund");

        mtsToken.safeTransfer(msg.sender, payableAmount);
        accountedBalance -= payableAmount;

        rewards[msg.sender] = reward - payableAmount;

        if (totalCrystallizedRewards >= payableAmount) {
            totalCrystallizedRewards -= payableAmount;
        } else {
            totalCrystallizedRewards  = 0;
        }

        // Post-claim invariant:
        //   accountedBalance >= rewardReserve + totalCrystallizedRewards
        //
        // After payout, accountedBalance may fall below reserve +
        // crystallized because reserve tokens have not yet been emitted.
        // Reduce rewardReserve first (least-committed liability), then
        // totalCrystallizedRewards if needed. These are accounting-only
        // corrections; they never reduce what any user can claim.
        uint256 liability = rewardReserve + totalCrystallizedRewards;
        if (liability > accountedBalance) {
            uint256 deficit = liability - accountedBalance;
            if (rewardReserve >= deficit) {
                rewardReserve -= deficit;
            } else {
                deficit -= rewardReserve;
                rewardReserve = 0;
                totalCrystallizedRewards = totalCrystallizedRewards >= deficit
                    ? totalCrystallizedRewards - deficit
                    : 0;
            }
        }

        emit RewardClaimed(msg.sender, payableAmount);
        if (rewards[msg.sender] > 0) {
            emit RewardDeferred(msg.sender, rewards[msg.sender]);
        }
    }

    // ═════════════════════════════════════════════════════════
    // FUND POOL — permissionless, anyone may call
    // ═════════════════════════════════════════════════════════
    function fundRewards(uint256 amount)
        external nonReentrant updateReward(address(0))
    {
        require(amount > 0, "Cannot fund 0");
        uint256 balBefore    = mtsToken.balanceOf(address(this));
        mtsToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = mtsToken.balanceOf(address(this)) - balBefore;
        rewardReserve    += actualAmount;
        accountedBalance += actualAmount;
        emit PoolFunded(msg.sender, actualAmount);
    }

    // ═════════════════════════════════════════════════════════
    // POOL HEALTH — read-only diagnostics, callable by anyone
    // ═════════════════════════════════════════════════════════

    /**
     * @notice Returns a full snapshot of pool accounting state.
     *
     * @dev    Liability definition:
     *           totalLiab = reserve + crystallized + uncrystallized
     *         where:
     *           reserve        = tokens scheduled for future emission
     *                            (rewardReserve)
     *           crystallized   = rewards earned and snapshotted but
     *                            not yet claimed (totalCrystallizedRewards)
     *           uncrystallized = rewards currently accruing since the
     *                            last global update but not yet
     *                            snapshotted (totalUncrystallizedRewards())
     *
     *         isSolvent        = realBal >= totalLiab   (on-chain truth)
     *         accountingSolvent= accBal  >= totalLiab   (internal accounting)
     *
     *         If isSolvent is true but accountingSolvent is false, the
     *         difference represents direct-transfer donations that were
     *         never routed through fundRewards(). See the PERMANENT
     *         DONATION NOTE at the top of this file — this is expected
     *         and permanent, not an error requiring action.
     *
     * @return actualBalance      mtsToken.balanceOf(this) — real on-chain balance.
     * @return internalBalance    accountedBalance — state-tracked balance.
     * @return reserve            rewardReserve.
     * @return crystallized       totalCrystallizedRewards.
     * @return uncrystallized     Currently accruing, not yet snapshotted.
     * @return totalLiab          reserve + crystallized + uncrystallized.
     * @return globalHashPower    totalGlobalHashPower.
     * @return emissionRatePerSec Current per-second emission rate (halving-adjusted).
     * @return pendingEmission    Tokens that would be distributed if updated now.
     * @return isSolvent          true when realBal >= totalLiab.
     * @return accountingSolvent  true when accountedBalance >= totalLiab.
     */
    function poolHealth() external view returns (
        uint256 actualBalance,
        uint256 internalBalance,
        uint256 reserve,
        uint256 crystallized,
        uint256 uncrystallized,
        uint256 totalLiab,
        uint256 globalHashPower,
        uint256 emissionRatePerSec,
        uint256 pendingEmission,
        bool isSolvent,
        bool accountingSolvent
    ) {
        actualBalance = mtsToken.balanceOf(address(this));
        internalBalance = accountedBalance;
        reserve = rewardReserve;
        crystallized = totalCrystallizedRewards;
        uncrystallized = totalUncrystallizedRewards();

        totalLiab = reserve + crystallized + uncrystallized;
        globalHashPower = totalGlobalHashPower;
        emissionRatePerSec = getCurrentEmissionRate();

        if (
            totalGlobalHashPower > 0 &&
            rewardReserve > 0 &&
            block.timestamp > lastUpdateTime
        ) {
            pendingEmission = _getCappedEmission(
                lastUpdateTime,
                block.timestamp,
                rewardReserve,
                totalCrystallizedRewards,
                accountedBalance
            );
        }

        isSolvent = actualBalance >= totalLiab;
        accountingSolvent = internalBalance >= totalLiab;
    }

    // ═════════════════════════════════════════════════════════
    // RENOUNCE OWNERSHIP
    //
    // This is the ONLY function in the entire contract that was
    // ever restricted to onlyOwner. After this is called once,
    // owner() permanently returns address(0) and no privileged
    // path remains anywhere in this contract.
    // ═════════════════════════════════════════════════════════
    function renounceOwnership() public override onlyOwner {
        address old = owner();
        emit ProtocolDecentralized(old);
        super.renounceOwnership();
    }

    // ═════════════════════════════════════════════════════════
    // ERC721 OVERRIDES
    // ═════════════════════════════════════════════════════════
    function _update(address to, uint256 tokenId, address auth)
        internal override(ERC721) returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0)) {
            require(
                nftStaker[tokenId] == address(0),
                "Cannot transfer: NFT is currently staked"
            );
        }
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId)
        public view override(ERC721) returns (string memory)
    {
        _requireOwned(tokenId);
        uint8 tier = nftTier[tokenId];
        if (tier == 1) return basicURI;
        if (tier == 2) return advancedURI;
        return eliteURI;
    }
}
