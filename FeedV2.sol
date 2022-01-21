//SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./Authorizable.sol";
import "./ChickenRunV4.sol";
import "./EggV2.sol";

import "hardhat/console.sol";

contract FeedV2 is ERC20, Authorizable {
    using SafeMath for uint256;

    uint256 public MAX_FEED_SUPPLY = 32000000000000000000000000000;
    string private TOKEN_NAME = "chikn feed";
    string private TOKEN_SYMBOL = "FEED";

    address public CHIKN_CONTRACT;
    address public EGG_CONTRACT;

    uint256 public BOOSTER_MULTIPLIER = 1;
    uint256 public FEED_FARMING_FACTOR = 3; // egg to feed ratio
    uint256 public FEED_SWAP_FACTOR = 12; // swap egg for feed ratio

    // Moved "SKIP_COOLDOWN_BASE" to EggV2 contract
    // Moved "SKIP_COOLDOWN_BASE_FACTOR" to EggV2 contract

    // feed mint event
    event Minted(address owner, uint256 numberOfFeed);
    event Burned(address owner, uint256 numberOfFeed);
    event EggSwap(address owner, uint256 numberOfFeed);
    // egg event
    event MintedEgg(address owner, uint256 numberOfFeed);
    event BurnedEgg(address owner, uint256 numberOfEggs);
    event StakedEgg(address owner, uint256 numberOfEggs);
    event UnstakedEgg(address owner, uint256 numberOfEggs);

    // Egg staking
    struct EggStake {
        // user wallet - who we have to pay back for the staked egg.
        address user;
        // used to calculate how much feed since.
        uint32 since;
        // amount of eggs that have been staked.
        uint256 amount;
    }

    mapping(address => EggStake) public eggStakeHolders;
    uint256 public totalEggStaked;
    address[] public _allEggsStakeHolders;
    mapping(address => uint256) private _allEggsStakeHoldersIndex;

    // egg stake and unstake
    event EggStaked(address user, uint256 amount);
    event EggUnStaked(address user, uint256 amount);

    constructor(address _chiknContract, address _eggContract)
        ERC20(TOKEN_NAME, TOKEN_SYMBOL)
    {
        CHIKN_CONTRACT = _chiknContract;
        EGG_CONTRACT = _eggContract;
    }

    /**
     * pdates user's amount of staked eggs to the given value. Resets the "since" timestamp.
     */
    function _upsertEggStaking(
        address user,
        uint256 amount
    ) internal {
        // NOTE does this ever happen?
        require(user != address(0), "EMPTY ADDRESS");
        EggStake memory egg = eggStakeHolders[user];

        // if first time user is staking $egg...
        if (egg.user == address(0)) {
            // add tracker for first time staker
            _allEggsStakeHoldersIndex[user] = _allEggsStakeHolders.length;
            _allEggsStakeHolders.push(user);
        }
        // since its an upsert, we took out old egg and add new amount
        uint256 previousEggs = egg.amount;
        // update stake
        egg.user = user;
        egg.amount = amount;
        egg.since = uint32(block.timestamp);

        eggStakeHolders[user] = egg;
        totalEggStaked = totalEggStaked - previousEggs + amount;
        emit EggStaked(user, amount);
    }

    function staking(uint256 amount) external {
        require(amount > 0, "NEED EGG");
        EggV2 eggContract = EggV2(EGG_CONTRACT);
        uint256 available = eggContract.balanceOf(msg.sender);
        require(available >= amount, "NOT ENOUGH EGG");
        EggStake memory existingEgg = eggStakeHolders[msg.sender];
        if (existingEgg.amount > 0) {
            // already have previous egg staked
            // need to calculate claimable
            uint256 projection = claimableView(msg.sender);
            // mint feed to wallet
            _mint(msg.sender, projection);
            emit Minted(msg.sender, amount);
            _upsertEggStaking(msg.sender, existingEgg.amount + amount);
        } else {
            // no egg staked just update staking
            _upsertEggStaking(msg.sender, amount);
        }
        eggContract.burnEggs(msg.sender, amount);
        emit StakedEgg(msg.sender, amount);
    }

    /**
     * Calculates how much feed is available to claim.
     */
    function claimableView(address user) public view returns (uint256) {
        EggStake memory egg = eggStakeHolders[user];
        require(egg.user != address(0), "NOT STAKED");
        // need to add 10000000000 to factor for decimal
        return
            ((egg.amount * FEED_FARMING_FACTOR) *
                (((block.timestamp - egg.since) * 10000000000) / 86400) *
                BOOSTER_MULTIPLIER) /
            10000000000;
    }

    // NOTE withdrawing egg without claiming feed
    function withdrawEgg(uint256 amount) external {
        require(amount > 0, "MUST BE MORE THAN 0");
        EggStake memory egg = eggStakeHolders[msg.sender];
        require(egg.user != address(0), "NOT STAKED");
        require(amount <= egg.amount, "OVERDRAWN");
        EggV2 eggContract = EggV2(EGG_CONTRACT);
        // uint256 projection = claimableView(msg.sender);
        _upsertEggStaking(msg.sender, egg.amount - amount);
        // Need to burn 1/12 when withdrawing (breakage fee)
        uint256 afterBurned = (amount * 11) / 12;
        // mint egg to return to user
        eggContract.mintEgg(msg.sender, afterBurned);
        emit UnstakedEgg(msg.sender, afterBurned);
    }

    /**
     * Claims feed from staked Egg
     */
    function claimFeed() external {
        uint256 projection = claimableView(msg.sender);
        require(projection > 0, "NO FEED TO CLAIM");

        EggStake memory egg = eggStakeHolders[msg.sender];

        // Updates user's amount of staked eggs to the given value. Resets the "since" timestamp.
        _upsertEggStaking(msg.sender, egg.amount);

        // check: that the total Feed supply hasn't been exceeded.
        _mintFeed(msg.sender, projection);
    }

    /**
     */
    function _removeUserFromEggEnumeration(address user) private {
        uint256 lastUserIndex = _allEggsStakeHolders.length - 1;
        uint256 currentUserIndex = _allEggsStakeHoldersIndex[user];

        address lastUser = _allEggsStakeHolders[lastUserIndex];

        _allEggsStakeHolders[currentUserIndex] = lastUser; // Move the last token to the slot of the to-delete token
        _allEggsStakeHoldersIndex[lastUser] = currentUserIndex; // Update the moved token's index

        // This also deletes the contents at the last position of the array
        delete _allEggsStakeHoldersIndex[user];
        _allEggsStakeHolders.pop();
    }

    /**
     * Unstakes the eggs, returns the Eggs (mints) to the user.
     */
    function withdrawAllEggAndClaimFeed() external {
        EggStake memory egg = eggStakeHolders[msg.sender];

        // NOTE does this ever happen?
        require(egg.user != address(0), "NOT STAKED");

        // if there's feed to claim, supply it to the owner...
        uint256 projection = claimableView(msg.sender);
        if (projection > 0) {
            // supply feed to the sender...
            _mintFeed(msg.sender, projection);
        }
        // if there's egg to withdraw, supply it to the owner...
        if (egg.amount > 0) {
            // mint egg to return to user
            // Need to burn 1/12 when withdrawing (breakage fee)
            uint256 afterBurned = (egg.amount * 11) / 12;
            EggV2 eggContract = EggV2(EGG_CONTRACT);
            eggContract.mintEgg(msg.sender, afterBurned);
            emit UnstakedEgg(msg.sender, afterBurned);
        }
        // Internal: removes egg from storage.
        _unstakingEgg(msg.sender);
    }

    /**
     * Internal: removes egg from storage.
     */
    function _unstakingEgg(address user) internal {
        EggStake memory egg = eggStakeHolders[user];
        // NOTE when whould address be zero?
        require(egg.user != address(0), "EMPTY ADDRESS");
        totalEggStaked = totalEggStaked - egg.amount;
        _removeUserFromEggEnumeration(user);
        delete eggStakeHolders[user];
        emit EggUnStaked(user, egg.amount);
    }

    /**
     * Feeds the chikn the amount of Feed.
     */
    function feedChikn(uint256 chiknId, uint256 amount) external {
        // check: amount is gt zero...
        require(amount > 0, "MUST BE MORE THAN 0 FEED");

        IERC721 instance = IERC721(CHIKN_CONTRACT);

        // check: msg.sender is chikn owner...
        require(instance.ownerOf(chiknId) == msg.sender, "NOT OWNER");
        
        // check: user has enough feed in wallet...
        require(balanceOf(msg.sender) >= amount, "NOT ENOUGH FEED");
        
        // TODO should this be moved to egg contract? or does the order here, matter?
        EggV2 eggContract = EggV2(EGG_CONTRACT);
        (uint24 kg, , , , ) = eggContract.stakedChikn(chiknId);
        require(kg > 0, "NOT STAKED");

        // burn feed...
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);

        // update eatenAmount in EggV2 contract...
        eggContract.feedChikn(chiknId, amount);
    }

    // Moved "levelup" to the EggV2 contract - it doesn't need anything from Feed contract.

    // Moved "skipCoolingOff" to the EggV2 contract - it doesn't need anything from Feed contract.

    function swapEggForFeed(uint256 eggAmt) external {
        require(eggAmt > 0, "MUST BE MORE THAN 0 EGG");

        // burn eggs...
        EggV2 eggContract = EggV2(EGG_CONTRACT);
        eggContract.burnEggs(msg.sender, eggAmt);

        // supply feed...
        _mint(msg.sender, eggAmt * FEED_SWAP_FACTOR);
        emit EggSwap(msg.sender, eggAmt * FEED_SWAP_FACTOR);
    }

    /**
     * Internal: mints the feed to the given wallet.
     */
    function _mintFeed(address sender, uint256 feedAmount) internal {
        // check: that the total Feed supply hasn't been exceeded.
        require(totalSupply() + feedAmount < MAX_FEED_SUPPLY, "OVER MAX SUPPLY");
        _mint(sender, feedAmount);
        emit Minted(sender, feedAmount);
    }

    // ADMIN FUNCTIONS

    /**
     * Admin : mints the feed to the given wallet.
     */
    function mintFeed(address sender, uint256 amount) external onlyOwner {
        _mintFeed(sender, amount);
    }

    /**
     * Admin : used for temporarily multipling how much feed is distributed per staked egg.
     */
    function updateBoosterMultiplier(uint256 _value) external onlyOwner {
        BOOSTER_MULTIPLIER = _value;
    }

    /**
     * Admin : updates how much feed you get per staked egg (e.g. 3x).
     */
    function updateFarmingFactor(uint256 _value) external onlyOwner {
        FEED_FARMING_FACTOR = _value;
    }

    /**
     * Admin : updates the multiplier for swapping (burning) egg for feed (e.g. 12x).
     */
    function updateFeedSwapFactor(uint256 _value) external onlyOwner {
        FEED_SWAP_FACTOR = _value;
    }

    /**
     * Admin : updates the maximum available feed supply.
     */
    function updateMaxFeedSupply(uint256 _value) external onlyOwner {
        MAX_FEED_SUPPLY = _value;
    }

    /**
     * Admin : util for working out how many people are staked.
     */
    function totalEggHolder() public view returns (uint256) {
        return _allEggsStakeHolders.length;
    }

    /**
     * Admin : gets the wallet for the the given index. Used for rebalancing.
     */
    function getEggHolderByIndex(uint256 index) internal view returns (address){
        return _allEggsStakeHolders[index];
    }

    /**
     * Admin : Rebalances the pool. Mint to the user's wallet. Only called if changing multiplier.
     */
    function rebalanceStakingPool(uint256 from, uint256 to) external onlyOwner {
        // for each holder of staked Egg...
        for (uint256 i = from; i <= to; i++) {
            address holderAddress = getEggHolderByIndex(i);

            // check how much feed is claimable...
            uint256 pendingClaim = claimableView(holderAddress);
            EggStake memory egg = eggStakeHolders[holderAddress];

            // supply Feed to the owner's wallet...
            _mint(holderAddress, pendingClaim);
            emit Minted(holderAddress, pendingClaim);

            // pdates user's amount of staked eggs to the given value. Resets the "since" timestamp.
            _upsertEggStaking(holderAddress, egg.amount);
        }
    }
}
