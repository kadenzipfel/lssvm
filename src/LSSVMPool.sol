// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICurve} from "./bonding-curves/ICurve.sol";
import {CurveErrorCodes} from "./bonding-curves/CurveErrorCodes.sol";
import {LSSVMPairFactory} from "./LSSVMPairFactory.sol";

contract LSSVMPool is OwnableUpgradeable, ERC721Holder, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using Address for address payable;

    enum PoolType {
        Buy,
        Sell,
        Trade
    }

    uint256 private constant MAX_FEE = 9e17; // 90%, must <= 1 - MAX_PROTOCOL_FEE

    struct TradedNFT {
        IERC721 nft;
        ICurve bondingCurve;
        PoolType poolType;
        uint256 spotPrice;
        uint256 delta;
        uint256 fee;
    }
    TradedNFT[] public tradedNFTs;
    mapping(uint256 => EnumerableSet.UintSet) internal tradedNFTsIDSet;

    LSSVMPairFactory public factory;
    bool internal canReceiveNFTs;

    modifier receiveNFTs() {
        canReceiveNFTs = true;
        _;
        canReceiveNFTs = false;
    }

    function initialize(LSSVMPairFactory _factory)
        external
        payable
        initializer
    {
        factory = _factory;
        __Ownable_init();
    }

    // Sell X ETH to Pool, get back at least Y NFTs
    function swapETHForAnyNFTs(uint256 _tradedNFTIndex, uint256 numNFTs)
        external
        payable
        nonReentrant
    {
        TradedNFT storage _tradedNFT = tradedNFTs[_tradedNFTIndex];
        IERC721 _nft = _tradedNFT.nft;
        LSSVMPairFactory _factory = factory;
        EnumerableSet.UintSet storage _idSet = tradedNFTsIDSet[_tradedNFTIndex];

        // do bonding curve computation
        require(
            (numNFTs > 0) && (numNFTs <= _nft.balanceOf(address(this))),
            "Must ask for > 0 and < balanceOf NFTs"
        );
        (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 inputAmount,
            uint256 protocolFee
        ) = _tradedNFT.bondingCurve.getBuyInfo(
                _tradedNFT.spotPrice,
                _tradedNFT.delta,
                numNFTs,
                _tradedNFT.fee,
                _factory.protocolFeeMultiplier()
            );
        require(error == CurveErrorCodes.Error.OK, "Bonding curve error");
        require(msg.value >= inputAmount, "Sent too little ETH");
        _tradedNFT.spotPrice = newSpotPrice;

        // transfer NFTs to sender
        for (uint256 i = 0; i < numNFTs; i++) {
            uint256 nftId = _idSet.at(0);
            _nft.safeTransferFrom(address(this), msg.sender, nftId);
            require(_idSet.remove(nftId), "NOT_IN_SET");
        }

        // transfer ETH
        uint256 feeDifference = msg.value - inputAmount;
        if (feeDifference > 0) {
            payable(msg.sender).sendValue(feeDifference);
        }
        if (protocolFee > 0) {
            _factory.protocolFeeRecipient().sendValue(protocolFee);
        }
    }

    // Sell X ETH to Pool, get back at least Y specific NFTs
    function swapETHForNFTs(uint256 _tradedNFTIndex, uint256[] calldata nftIds)
        external
        payable
        nonReentrant
    {
        TradedNFT storage _tradedNFT = tradedNFTs[_tradedNFTIndex];
        IERC721 _nft = _tradedNFT.nft;
        LSSVMPairFactory _factory = factory;
        EnumerableSet.UintSet storage _idSet = tradedNFTsIDSet[_tradedNFTIndex];

        // do bonding curve computation
        require(
            (nftIds.length > 0) &&
                (nftIds.length <= _nft.balanceOf(address(this))),
            "Must ask for > 0 and < balanceOf NFTs"
        );
        (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 inputAmount,
            uint256 protocolFee
        ) = _tradedNFT.bondingCurve.getBuyInfo(
                _tradedNFT.spotPrice,
                _tradedNFT.delta,
                nftIds.length,
                _tradedNFT.fee,
                _factory.protocolFeeMultiplier()
            );
        require(error == CurveErrorCodes.Error.OK, "Bonding curve error");
        require(msg.value >= inputAmount, "Sent too little ETH");
        _tradedNFT.spotPrice = newSpotPrice;

        // transfer NFTs to sender
        for (uint256 i = 0; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];
            _nft.safeTransferFrom(address(this), msg.sender, nftId);
            require(_idSet.remove(nftId), "NOT_IN_SET");
        }

        // transfer ETH
        uint256 feeDifference = msg.value - inputAmount;
        if (feeDifference > 0) {
            payable(msg.sender).sendValue(feeDifference);
        }
        if (protocolFee > 0) {
            _factory.protocolFeeRecipient().sendValue(protocolFee);
        }
    }

    // Sell X specific NFTs to Pool, get back at least Y ETH
    function swapNFTsForETH(
        uint256 _tradedNFTIndex,
        uint256[] calldata nftIds,
        uint256 minExpectedETHOutput
    ) external nonReentrant receiveNFTs {
        TradedNFT storage _tradedNFT = tradedNFTs[_tradedNFTIndex];
        IERC721 _nft = _tradedNFT.nft;
        LSSVMPairFactory _factory = factory;
        EnumerableSet.UintSet storage _idSet = tradedNFTsIDSet[_tradedNFTIndex];

        // do bonding curve computation
        (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 outputAmount,
            uint256 protocolFee
        ) = _tradedNFT.bondingCurve.getSellInfo(
                _tradedNFT.spotPrice,
                _tradedNFT.delta,
                nftIds.length,
                _tradedNFT.fee,
                _factory.protocolFeeMultiplier()
            );
        require(error == CurveErrorCodes.Error.OK, "Bonding curve error");
        require(outputAmount >= minExpectedETHOutput, "Out too little ETH");
        _tradedNFT.spotPrice = newSpotPrice;

        // transfer NFTs from sender
        for (uint256 i = 0; i < nftIds.length; i++) {
            _nft.safeTransferFrom(msg.sender, address(this), nftIds[i]);
            _idSet.add(nftIds[i]);
        }

        // transfer ETH
        if (outputAmount > 0) {
            payable(msg.sender).sendValue(outputAmount);
        }
        if (protocolFee > 0) {
            _factory.protocolFeeRecipient().sendValue(protocolFee);
        }
    }

    function registerTradedNFT(
        IERC721 _nft,
        ICurve _bondingCurve,
        PoolType _poolType,
        uint256 _delta,
        uint256 _fee,
        uint256 _spotPrice
    ) external onlyOwner nonReentrant {
        TradedNFT memory t = _validateTradedNFT(
            _nft,
            _bondingCurve,
            _poolType,
            _delta,
            _fee,
            _spotPrice
        );
        tradedNFTs.push(t);
    }

    function updateTradedNFT(
        uint256 _tradedNFTIndex,
        IERC721 _nft,
        ICurve _bondingCurve,
        PoolType _poolType,
        uint256 _delta,
        uint256 _fee,
        uint256 _spotPrice
    ) external onlyOwner nonReentrant {
        TradedNFT memory t = _validateTradedNFT(
            _nft,
            _bondingCurve,
            _poolType,
            _delta,
            _fee,
            _spotPrice
        );
        tradedNFTs[_tradedNFTIndex] = t;
    }

    function _validateTradedNFT(
        IERC721 _nft,
        ICurve _bondingCurve,
        PoolType _poolType,
        uint256 _delta,
        uint256 _fee,
        uint256 _spotPrice
    ) internal pure returns (TradedNFT memory t) {
        if ((_poolType == PoolType.Buy) || (_poolType == PoolType.Sell)) {
            require(_fee == 0, "Only Trade Pools can have nonzero fee");
        }
        if (_poolType == PoolType.Trade) {
            require(_fee < MAX_FEE, "Trade fee must be less than 100%");
        }
        require(_bondingCurve.validateDelta(_delta), "Invalid delta for curve");
        t.nft = _nft;
        t.bondingCurve = _bondingCurve;
        t.poolType = _poolType;
        t.delta = _delta;
        t.fee = _fee;
        t.spotPrice = _spotPrice;
    }

    // Withdraw X ETH
    function withdrawETH(uint256 amount) public onlyOwner {
        payable(owner()).sendValue(amount);
    }

    // Withdraw all ETH
    function withdrawAllETH() external onlyOwner {
        withdrawETH(address(this).balance);
    }

    function depositNFTs(uint256 _tradedNFTIndex, uint256[] calldata _nftIds)
        external
        onlyOwner
        nonReentrant
        receiveNFTs
    {
        IERC721 _nft = tradedNFTs[_tradedNFTIndex].nft;
        EnumerableSet.UintSet storage _idSet = tradedNFTsIDSet[_tradedNFTIndex];

        for (uint256 i = 0; i < _nftIds.length; i++) {
            _nft.safeTransferFrom(msg.sender, address(this), _nftIds[i]);
            _idSet.add(_nftIds[i]);
        }
    }

    // Withdraw Y NFTs
    function withdrawNFTs(uint256 _tradedNFTIndex, uint256[] calldata _nftIds)
        external
        onlyOwner
        nonReentrant
    {
        IERC721 _nft = tradedNFTs[_tradedNFTIndex].nft;
        EnumerableSet.UintSet storage _idSet = tradedNFTsIDSet[_tradedNFTIndex];

        for (uint256 i = 0; i < _nftIds.length; i++) {
            _nft.safeTransferFrom(address(this), msg.sender, _nftIds[i]);
            require(_idSet.remove(_nftIds[i]), "NOT_IN_SET");
        }
    }

    function onERC721Received(
        address a1,
        address a2,
        uint256 id,
        bytes memory b
    ) public virtual override returns (bytes4) {
        require(canReceiveNFTs, "NOT_RECEIVING");
        return super.onERC721Received(a1, a2, id, b);
    }

    function changeSpotPrice(uint256 _tradedNFTIndex, uint256 newSpotPrice)
        external
        onlyOwner
    {
        tradedNFTs[_tradedNFTIndex].spotPrice = newSpotPrice;
    }

    function changeDelta(uint256 _tradedNFTIndex, uint256 newDelta)
        external
        onlyOwner
    {
        require(
            tradedNFTs[_tradedNFTIndex].bondingCurve.validateDelta(newDelta),
            "Invalid delta for curve"
        );
        tradedNFTs[_tradedNFTIndex].delta = newDelta;
    }

    function changeFee(uint256 _tradedNFTIndex, uint256 newFee)
        external
        onlyOwner
    {
        require(
            tradedNFTs[_tradedNFTIndex].poolType == PoolType.Trade,
            "Only for Trade pools"
        );
        require(newFee < MAX_FEE, "Trade fee must be less than 90%");
        tradedNFTs[_tradedNFTIndex].fee = newFee;
    }

    receive() external payable {}
}
