pragma solidity ^0.5.6;

import "./klaytn-contracts/token/KIP17/IKIP17Enumerable.sol";
import "./klaytn-contracts/math/SafeMath.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/ITurntableKIP17Listeners.sol";
import "./interfaces/IMixEmitter.sol";
import "./interfaces/IMix.sol";
import "./interfaces/ITurntables.sol";

contract TurntableKIP17Listeners is ITurntableKIP17Listeners {
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    IMixEmitter private mixEmitter;
    IMix private mix;
    uint256 private pid;
    ITurntables private turntables;
    IKIP17Enumerable private nft;

    constructor(
        IMixEmitter _mixEmitter,
        IMix _mix,
        uint256 _pid,
        ITurntables _turntables,
        IKIP17Enumerable _nft
    ) public {
        mixEmitter = _mixEmitter;
        mix = _mix;
        pid = _pid;
        turntables = _turntables;
        nft = _nft;
    }

    uint256 private currentBalance = 0;
    uint256 private totalShares = 0;
    mapping(uint256 => mapping(uint256 => uint256)) private shares;

    uint256 private turntableFee = 300; // 1e4
    mapping(uint256 => uint256) private listeningTo;
    mapping(uint256 => bool) private listening;

    uint256 constant private pointsMultiplier = 2**128;
    uint256 private pointsPerShare = 0;
    mapping(uint256 => mapping(uint256 => int256)) private pointsCorrection;
    mapping(uint256 => mapping(uint256 => uint256)) private claimed;

    function updateBalance() private {
        if (totalShares > 0) {
            mixEmitter.updatePool(pid);
            uint256 balance = mix.balanceOf(address(this));
            uint256 value = balance.sub(currentBalance);
            if (value > 0) {
                pointsPerShare = pointsPerShare.add(value.mul(pointsMultiplier).div(totalShares));
                emit Distribute(msg.sender, value);
            }
            currentBalance = balance;
        }
    }

    function claimedOf(uint256 turntableId, uint256 id) public view returns (uint256) {
        return claimed[turntableId][id];
    }

    function accumulativeOf(uint256 turntableId, uint256 id) public view returns (uint256) {
        uint256 _pointsPerShare = pointsPerShare;
        if (totalShares > 0) {
            uint256 balance = mixEmitter.pendingMix(pid).add(mix.balanceOf(address(this)));
            uint256 value = balance.sub(currentBalance);
            if (value > 0) {
                _pointsPerShare = _pointsPerShare.add(value.mul(pointsMultiplier).div(totalShares));
            }
            return uint256(int256(_pointsPerShare.mul(shares[turntableId][id])).add(pointsCorrection[turntableId][id])).div(pointsMultiplier);
        }
        return 0;
    }

    function claimableOf(uint256 turntableId, uint256 id) external view returns (uint256) {
        return accumulativeOf(turntableId, id).sub(claimed[turntableId][id]);
    }

    function _accumulativeOf(uint256 turntableId, uint256 id) private view returns (uint256) {
        return uint256(int256(pointsPerShare.mul(shares[turntableId][id])).add(pointsCorrection[turntableId][id])).div(pointsMultiplier);
    }

    function _claimableOf(uint256 turntableId, uint256 id) private view returns (uint256) {
        return _accumulativeOf(turntableId, id).sub(claimed[turntableId][id]);
    }

    function claim(uint256 turntableId, uint256[] calldata ids) external {
        updateBalance();
        uint256 length = ids.length;
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < length; i = i.add(1)) {
            uint256 id = ids[i];
            require(nft.ownerOf(id) == msg.sender && listening[id] == true && listeningTo[id] == turntableId);
            uint256 claimable = _claimableOf(turntableId, id);
            if (claimable > 0) {
                claimed[turntableId][id] = claimed[turntableId][id].add(claimable);
                emit Claim(turntableId, id, claimable);
                uint256 fee = claimable.mul(turntableFee).div(1e4);
                if (turntables.exists(turntableId) == true) {
                    mix.transfer(turntables.ownerOf(turntableId), fee);
                } else {
                    mix.burn(fee);
                }
                mix.transfer(msg.sender, claimable.sub(fee));
                totalClaimable = totalClaimable.add(claimable);
            }
        }
        currentBalance = currentBalance.sub(totalClaimable);
    }

    function listen(uint256 turntableId, uint256[] calldata ids) external {
        updateBalance();
        uint256 length = ids.length;
        totalShares = totalShares.add(length);
        for (uint256 i = 0; i < length; i = i.add(1)) {
            uint256 id = ids[i];
            require(nft.ownerOf(id) == msg.sender && listening[id] != true);
            shares[turntableId][id] = shares[turntableId][id].add(1);
            pointsCorrection[turntableId][id] = pointsCorrection[turntableId][id].sub(int256(pointsPerShare));
            listeningTo[id] = turntableId;
            listening[id] = true;
            emit Listen(turntableId, msg.sender, id);
        }
    }

    function unlisten(uint256 turntableId, uint256[] calldata ids) external {
        updateBalance();
        uint256 length = ids.length;
        totalShares = totalShares.sub(length);
        for (uint256 i = 0; i < length; i = i.add(1)) {
            uint256 id = ids[i];
            require(nft.ownerOf(id) == msg.sender && listening[id] == true && listeningTo[id] == turntableId);
            shares[turntableId][id] = shares[turntableId][id].sub(1);
            pointsCorrection[turntableId][id] = pointsCorrection[turntableId][id].add(int256(pointsPerShare));
            delete listeningTo[id];
            delete listening[id];
            emit Unlisten(turntableId, msg.sender, id);
        }
    }
}