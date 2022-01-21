//SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./Authorizable.sol";
import "./ChickenRunV4.sol";

import "hardhat/console.sol";

contract EggV2 is ERC20, Authorizable {
    using SafeMath for uint256;
    string private TOKEN_NAME = "chikn egg";
    string private TOKEN_SYMBOL = "EGG";

    address public CHIKN_CONTRACT;

    // the base number of $EGG per chikn (i.e. 0.75 $egg)
    uint256 public BASE_HOLDER_EGGS = 750000000000000000;

    // the number of $EGG per chikn per day per kg (i.e. 0.25 $egg /chikn /day /kg)
    uint256 public EGGS_PER_DAY_PER_KG = 250000000000000000;

    // how much egg it costs to skip the cooldown
    uint256 public COOLDOWN_BASE = 100000000000000000000; // base 100
    // how much additional egg it costs to skip the cooldown per kg
    uint256 public COOLDOWN_BASE_FACTOR = 100000000000000000000; // additional 100 per kg
    // how long to wait before skip cooldown can be re-invoked
    uint256 public COOLDOWN_CD_IN_SECS = 86400; // additional 100 per kg

    uint256 public LEVELING_BASE = 25;
    uint256 public LEVELING_RATE = 2;
    uint256 public COOLDOWN_RATE = 3600; // 60 mins

    // uint8 (0 - 255)
    // uint16 (0 - 65535)
    // uint24 (0 - 16,777,216)
    // uint32 (0 - 4,294,967,295)
    // uint40 (0 - 1,099,511,627,776)
    // unit48 (0 - 281,474,976,710,656)
    // uint256 (0 - 1.157920892e77)

    /**
     * Stores staked chikn fields (=> 152 <= stored in order of size for optimal packing!)
     */
    struct StakedChiknObj {
        // the current kg level (0 -> 16,777,216)
        uint24 kg;
        // when to calculate egg from (max 20/02/36812, 11:36:16)
        uint32 sinceTs;
        // for the skipCooldown's cooldown (max 20/02/36812, 11:36:16)
        uint32 lastSkippedTs;
        // how much this chikn has been fed (in whole numbers)
        uint48 eatenAmount;
        // cooldown time until level up is allow (per kg)
        uint32 cooldownTs;
    }

    // redundant struct - can't be packed? (max totalKg = 167,772,160,000)
    uint40 public totalKg;
    uint16 public totalStakedChikn;

    StakedChiknObj[100001] public stakedChikn;

    // Events

    event Minted(address owner, uint256 eggsAmt);
    event Burned(address owner, uint256 eggsAmt);
    event Staked(uint256 tid, uint256 ts);
    event UnStaked(uint256 tid, uint256 ts);

    // Constructor

    constructor(address _chiknContract) ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        CHIKN_CONTRACT = _chiknContract;
    }

    // "READ" Functions
    // How much is required to be fed to level up per kg

    function feedLevelingRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100, and make sure the feed level is at 18 decimals
        return LEVELING_BASE * ((kg / 100)**LEVELING_RATE);
    }

    // when using the value, need to add the current block timestamp as well
    function cooldownRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100

        return (kg / 100) * COOLDOWN_RATE;
    }

    // Staking Functions

    // stake chikn, check if is already staked, get all detail for chikn such as
    function _stake(uint256 tid) internal {
        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);

        // verify user is the owner of the chikn...
        require(x.ownerOf(tid) == msg.sender, "NOT OWNER");

        // get calc'd values...
        (, , , , , , , uint256 kg) = x.allChickenRun(tid);
        // if lastSkippedTs is 0 its mean it never have a last skip timestamp
        StakedChiknObj memory c = stakedChikn[tid];
        uint32 ts = uint32(block.timestamp);
        if (stakedChikn[tid].kg == 0) {
            // create staked chikn...
            stakedChikn[tid] = StakedChiknObj(
                uint24(kg),
                ts,
                c.lastSkippedTs > 0 ? c.lastSkippedTs :  uint32(ts - COOLDOWN_CD_IN_SECS),
                uint48(0),
                uint32(ts) + uint32(cooldownRate(kg)) 
            );

            // update snapshot values...
            // N.B. could be optimised for multi-stakes - but only saves 0.5c AUD per chikn - not worth it, this is a one time operation.
            totalStakedChikn += 1;
            totalKg += uint24(kg);

            // let ppl know!
            emit Staked(tid, block.timestamp);
        }
    }

    // function staking(uint256 tokenId) external {
    //     _stake(tokenId);
    // }

    function stake(uint256[] calldata tids) external {
        for (uint256 i = 0; i < tids.length; i++) {
            _stake(tids[i]);
        }
    }

    /**
     * Calculates the amount of egg that is claimable from a chikn.
     */
    function claimableView(uint256 tokenId) public view returns (uint256) {
        StakedChiknObj memory c = stakedChikn[tokenId];
        if (c.kg > 0) {
            uint256 eggPerDay = ((EGGS_PER_DAY_PER_KG * (c.kg / 100)) +
                BASE_HOLDER_EGGS);
            uint256 deltaSeconds = block.timestamp - c.sinceTs;
            return deltaSeconds * (eggPerDay / 86400);
        } else {
            return 0;
        }
    }

    // Removed "getChikn" to save space

    // struct ChiknObj {
    //     uint256 kg;
    //     uint256 sinceTs;
    //     uint256 lastSkippedTs;
    //     uint256 eatenAmount;
    //     uint256 cooldownTs;
    //     uint256 requireFeedAmount;
    // }

    // function getChikn(uint256 tokenId) public view returns (ChiknObj memory) {
    //     StakedChiknObj memory c = stakedChikn[tokenId];
    //     return
    //         ChiknObj(
    //             c.kg,
    //             c.sinceTs,
    //             c.lastSkippedTs,
    //             c.eatenAmount,
    //             c.cooldownTs,
    //             feedLevelingRate(c.kg)
    //         );
    // }

    /**
     * Get all MY staked chikn id
     */

    function myStakedChikn() public view returns (uint256[] memory) {
        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);
        uint256 chiknCount = x.balanceOf(msg.sender);
        uint256[] memory tokenIds = new uint256[](chiknCount);
        uint256 counter = 0;
        for (uint256 i = 0; i < chiknCount; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedChiknObj memory chikn = stakedChikn[tokenId];
            if (chikn.kg > 0) {
                tokenIds[counter] = tokenId;
                counter++;
            }
        }
        return tokenIds;
    }

    /**
     * Calculates the TOTAL amount of egg that is claimable from ALL chikns.
     */
    function myClaimableView() public view returns (uint256) {
        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);
        uint256 cnt = x.balanceOf(msg.sender);
        require(cnt > 0, "NO CHIKN");
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < cnt; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedChiknObj memory chikn = stakedChikn[tokenId];
            // make sure that the token is staked
            if (chikn.kg > 0) {
                uint256 claimable = claimableView(tokenId);
                if (claimable > 0) {
                    totalClaimable = totalClaimable + claimable;
                }
            }
        }
        return totalClaimable;
    }

    /**
     * Claims eggs from the provided chikns.
     */
    function _claimEggs(uint256[] calldata tokenIds) internal {
        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);
        uint256 totalClaimableEgg = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(x.ownerOf(tokenIds[i]) == msg.sender, "NOT OWNER");
            StakedChiknObj memory chikn = stakedChikn[tokenIds[i]];
            // we only care about chikn that have been staked (i.e. kg > 0) ...
            if (chikn.kg > 0) {
                uint256 claimableEgg = claimableView(tokenIds[i]);
                if (claimableEgg > 0) {
                    totalClaimableEgg = totalClaimableEgg + claimableEgg;
                    // reset since, for the next calc...
                    chikn.sinceTs = uint32(block.timestamp);
                    stakedChikn[tokenIds[i]] = chikn;
                }
            }
        }
        if (totalClaimableEgg > 0) {
            _mint(msg.sender, totalClaimableEgg);
            emit Minted(msg.sender, totalClaimableEgg);
        }
    }

    /**
     * Claims eggs from the provided chikns.
     */
    function claimEggs(uint256[] calldata tokenIds) external {
        _claimEggs(tokenIds);
    }

    /**
     * Unstakes a chikn. Why you'd call this, I have no idea.
     */
    function _unstake(uint256 tokenId) internal {
        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);

        // verify user is the owner of the chikn...
        require(x.ownerOf(tokenId) == msg.sender, "NOT OWNER");

        // update chikn...
        StakedChiknObj memory c = stakedChikn[tokenId];
        if (c.kg > 0) {
            // update snapshot values...
            totalKg -= uint24(c.kg);
            totalStakedChikn -= 1;

            c.kg = 0;
            stakedChikn[tokenId] = c;

            // let ppl know!
            emit UnStaked(tokenId, block.timestamp);
        }
    }

    function _unstakeMultiple(uint256[] calldata tids) internal {
        for (uint256 i = 0; i < tids.length; i++) {
            _unstake(tids[i]);
        }
    }

    /**
     * Unstakes MULTIPLE chikn. Why you'd call this, I have no idea.
     */
    function unstake(uint256[] calldata tids) external {
        _unstakeMultiple(tids);
    }

    /**
     * Unstakes MULTIPLE chikn AND claims the eggs.
     */
    function withdrawAllChiknAndClaim(uint256[] calldata tids) external {
        _claimEggs(tids);
        _unstakeMultiple(tids);
    }

    /**
     * Public : update the chikn's KG level.
     */
     function levelUpChikn(uint256 tid) external {
        StakedChiknObj memory c = stakedChikn[tid];
        require(c.kg > 0, "NOT STAKED");

        ChickenRunV4 x = ChickenRunV4(CHIKN_CONTRACT);
        // NOTE Does it matter if sender is not owner?
        // require(x.ownerOf(chiknId) == msg.sender, "NOT OWNER");

        // check: chikn has eaten enough...
        require(c.eatenAmount >= feedLevelingRate(c.kg), "MORE FOOD REQD");
        // check: cooldown has passed...
        require(block.timestamp >= c.cooldownTs, "COOLDOWN NOT MET");

        // increase kg, reset eaten to 0, update next feed level and cooldown time
        c.kg = c.kg + 100;
        c.eatenAmount = 0;
        c.cooldownTs = uint32(block.timestamp + cooldownRate(c.kg));
        stakedChikn[tid] = c;

        // need to increase overall size
        totalKg += uint24(100);

        // and update the chikn contract
        x.setKg(tid, c.kg);
    }

    /**
     * Internal: burns the given amount of eggs from the wallet.
     */
    function _burnEggs(address sender, uint256 eggsAmount) internal {
        // NOTE do we need to check this before burn?
        require(balanceOf(sender) >= eggsAmount, "NOT ENOUGH EGG");
        _burn(sender, eggsAmount);
        emit Burned(sender, eggsAmount);
    }

    /**
     * Burns the given amount of eggs from the sender's wallet.
     */
    function burnEggs(address sender, uint256 eggsAmount) external onlyAuthorized {
        _burnEggs(sender, eggsAmount);
    }

    /**
     * Skips the "levelUp" cooling down period, in return for burning Egg.
     */
     function skipCoolingOff(uint256 tokenId, uint256 eggAmt) external {
        StakedChiknObj memory chikn = stakedChikn[tokenId];
        require(chikn.kg != 0, "NOT STAKED");

        uint32 ts = uint32(block.timestamp);

        // NOTE Does it matter if sender is not owner?
        // ChickenRunV4 instance = ChickenRunV4(CHIKN_CONTRACT);
        // require(instance.ownerOf(chiknId) == msg.sender, "NOT OWNER");

        // check: enough egg in wallet to pay
        uint256 walletBalance = balanceOf(msg.sender);
        require( walletBalance >= eggAmt, "NOT ENOUGH EGG IN WALLET");

        // check: provided egg amount is enough to skip this level
        require(eggAmt >= checkSkipCoolingOffAmt(chikn.kg), "NOT ENOUGH EGG TO SKIP");

        // check: user hasn't skipped cooldown in last 24 hrs
        require((chikn.lastSkippedTs + COOLDOWN_CD_IN_SECS) <= ts, "BLOCKED BY 24HR COOLDOWN");

        // burn eggs
        _burnEggs(msg.sender, eggAmt);

        // disable cooldown
        chikn.cooldownTs = ts;
        // track last time cooldown was skipped (i.e. now)
        chikn.lastSkippedTs = ts;
        stakedChikn[tokenId] = chikn;
    }

    /**
     * Calculates the cost of skipping cooldown.
     */
    function checkSkipCoolingOffAmt(uint256 kg) public view returns (uint256) {
        // NOTE cannot assert KG is < 100... we can have large numbers!
        return ((kg / 100) * COOLDOWN_BASE_FACTOR);
    }

    /**
     * Feed Feeding the chikn
     */
    function feedChikn(uint256 tokenId, uint256 feedAmount)
        external
        onlyAuthorized
    {
        StakedChiknObj memory chikn = stakedChikn[tokenId];
        require(chikn.kg > 0, "NOT STAKED");
        require(feedAmount > 0, "NOTHING TO FEED");
        // update the block time as well as claimable
        chikn.eatenAmount = uint48(feedAmount / 1e18) + chikn.eatenAmount;
        stakedChikn[tokenId] = chikn;
    }

    // NOTE What happens if we update the multiplier, and people have been staked for a year...?
    // We need to snapshot somehow... but we're physically unable to update 10k records!!!

    // Removed "updateBaseEggs" - to make space

    // Removed "updateEggPerDayPerKg" - to make space

    // ADMIN: to update the cost of skipping cooldown
    function updateSkipCooldownValues(
        uint256 a, 
        uint256 b, 
        uint256 c,
        uint256 d,
        uint256 e
    ) external onlyOwner {
        COOLDOWN_BASE = a;
        COOLDOWN_BASE_FACTOR = b;
        COOLDOWN_CD_IN_SECS = c;
        BASE_HOLDER_EGGS = d;
        EGGS_PER_DAY_PER_KG = e;
    }

    // INTRA-CONTRACT: use this function to mint egg to users
    // this also get called by the FEED contract
    function mintEgg(address sender, uint256 amount) external onlyAuthorized {
        _mint(sender, amount);
        emit Minted(sender, amount);
    }

    // ADMIN: drop egg to the given chikn wallet owners (within the chiknId range from->to).
    function airdropToExistingHolder(
        uint256 from,
        uint256 to,
        uint256 amountOfEgg
    ) external onlyOwner {
        // mint 100 eggs to every owners
        ChickenRunV4 instance = ChickenRunV4(CHIKN_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            if (currentOwner != address(0)) {
                _mint(currentOwner, amountOfEgg * 1e18);
            }
        }
    }

    // ADMIN: Rebalance user wallet by minting egg (within the chiknId range from->to).
    // NOTE: This is use when we need to update egg production
    function rebalanceEggClaimableToUserWallet(uint256 from, uint256 to)
        external
        onlyOwner
    {
        ChickenRunV4 instance = ChickenRunV4(CHIKN_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            StakedChiknObj memory chikn = stakedChikn[i];
            // we only care about chikn that have been staked (i.e. kg > 0) ...
            if (chikn.kg > 0) {
                _mint(currentOwner, claimableView(i));
                chikn.sinceTs = uint32(block.timestamp);
                stakedChikn[i] = chikn;
            }
        }
    }
}
