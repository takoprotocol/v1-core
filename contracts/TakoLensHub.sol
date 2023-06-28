// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.17;

import "./access/Ownable.sol";
import "./libraries/DataTypes.sol";
import "./libraries/Errors.sol";
import "./interfaces/ILensHub.sol";
import "./libraries/SigUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TakoLensHub is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address LENS_HUB;

    enum BidType {
        Post,
        Comment,
        Mirror
    }

    struct BidData {
        string contentURI;
        uint256 profileIdPointed;
        uint256 pubIdPointed;
        address bidToken;
        uint256 bidAmount;
        uint256 duration;
        uint256[] toProfiles;
    }

    struct Content {
        string contentURI;
        uint256 profileIdPointed;
        uint256 pubIdPointed;
        address bidToken;
        address bidAddress;
        uint256 bidAmount;
        uint256 bidExpires;
        uint256[] toProfiles;
        DataTypes.AuditState state;
        BidType bidType;
    }

    struct MomokaBidData {
        string contentURI;
        string mirror;
        string commentOn;
        address bidToken;
        uint256 bidAmount;
        uint256 duration;
        uint256[] toProfiles;
    }

    struct MomokaContent {
        string mirror;
        string commentOn;
        string contentURI;
        address bidToken;
        address bidAddress;
        uint256 bidAmount;
        uint256 bidExpires;
        uint256[] toProfiles;
        DataTypes.AuditState state;
        BidType bidType;
    }
    string public constant name = "Tako Lens Hub";
    bytes32 internal constant LOAN_WITH_SIG_TYPEHASH =
        keccak256(
            "LoanWithSig(uint256 index,address auditor,uint256 deadline)"
        );
    uint8 public maxToProfileCounter = 5;
    address public feeCollector;
    uint256 public feeRate = 1 * 10 ** 8;
    uint256 _bidCounter;
    mapping(uint256 => Content) internal _contentByIndex;
    mapping(address => bool) internal _bidTokenWhitelisted;
    mapping(address => mapping(address => uint256)) _minBidByTokenByWallet;
    mapping(address => mapping(BidType => bool)) _disableAuditType;

    uint256 _momokaBidCounter;
    mapping(uint256 => MomokaContent) internal _momokaContentByIndex;
    mapping(address => bool) internal _relayerWhitelisted;

    uint256 public constant FEE_DENOMINATOR = 10 ** 10;

    constructor(address lensHub) {
        LENS_HUB = lensHub;
        feeCollector = _msgSender();
    }

    receive() external payable {}

    // Gov
    function whitelistBidToken(
        address token,
        bool whitelist
    ) external onlyOwner {
        _bidTokenWhitelisted[token] = whitelist;
    }

    function whitelistRelayer(
        address relayer,
        bool whitelist
    ) external onlyOwner {
        _relayerWhitelisted[relayer] = whitelist;
    }

    function setLensHub(address hub) external onlyOwner {
        LENS_HUB = hub;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = _feeCollector;
    }

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        feeRate = _feeRate;
    }

    function setToProfileLimit(uint8 counter) external onlyOwner {
        maxToProfileCounter = counter;
    }

    // User
    function bid(BidData calldata vars, BidType bidType) external payable {
        _bid(vars, bidType);
    }

    function bidArray(
        BidData[] calldata vars,
        BidType[] calldata bidType
    ) external payable {
        for (uint256 i = 0; i < vars.length; i++) {
            _bid(vars[i], bidType[i]);
        }
    }

    function bidMomoka(
        MomokaBidData calldata vars,
        BidType bidType
    ) external payable {
        _bidMomoka(vars, bidType);
    }

    function bidMomokaArray(
        MomokaBidData[] calldata vars,
        BidType[] calldata bidType
    ) external payable {
        for (uint256 i = 0; i < vars.length; i++) {
            _bidMomoka(vars[i], bidType[i]);
        }
    }

    function cancelBid(uint256 index) external {
        _cancelBid(index);
    }

    function cancelBidArray(uint256[] calldata indexArr) external {
        for (uint256 i = 0; i < indexArr.length; i++) {
            _cancelBid(indexArr[i]);
        }
    }

    function cancelBidMomoka(uint256 index) external {
        _cancelBidMomoka(index);
    }

    function cancelBidMomokaArray(uint256[] calldata indexArr) external {
        for (uint256 i = 0; i < indexArr.length; i++) {
            _cancelBidMomoka(indexArr[i]);
        }
    }

    // Curator
    function settings(
        address token,
        uint256 min,
        bool[] calldata disableAuditTypes
    ) external {
        _setMinBid(token, min);
        _setDisableAuditTypes(disableAuditTypes);
    }

    function setMinBid(address token, uint256 min) external {
        _setMinBid(token, min);
    }

    function setDisableAuditTypes(bool[] calldata disableAuditTypes) external {
        _setDisableAuditTypes(disableAuditTypes);
    }

    function auditBidPost(
        uint256 index,
        uint256 profileId,
        DataTypes.EIP712Signature calldata sig
    ) external {
        _validateContentIndex(index);
        Content memory content = _contentByIndex[index];
        if (content.bidType != BidType.Post) {
            revert Errors.ParamsrInvalid();
        }
        if (content.state != DataTypes.AuditState.Pending) {
            revert Errors.BidIsClose();
        }
        _validateExpires(content.bidExpires);
        _validateProfile(profileId, content.toProfiles);
        ILensHub.PostWithSigData memory lensData;
        lensData.profileId = profileId;
        lensData.contentURI = content.contentURI;
        lensData.sig = DataTypes.EIP712Signature(
            sig.v,
            sig.r,
            sig.s,
            sig.deadline
        );
        _postWithSign(lensData);
        _loan(content.bidToken, content.bidAmount);
        _contentByIndex[index].state = DataTypes.AuditState.Pass;
    }

    function auditBidMirror(
        uint256 index,
        uint256 profileId,
        DataTypes.EIP712Signature calldata sig
    ) external {
        _validateContentIndex(index);
        Content memory content = _contentByIndex[index];
        if (content.bidType != BidType.Mirror) {
            revert Errors.ParamsrInvalid();
        }
        if (content.state != DataTypes.AuditState.Pending) {
            revert Errors.BidIsClose();
        }
        _validateExpires(content.bidExpires);
        _validateProfile(profileId, content.toProfiles);
        ILensHub.MirrorWithSigData memory lensData;
        lensData.profileId = profileId;
        lensData.profileIdPointed = content.profileIdPointed;
        lensData.pubIdPointed = content.pubIdPointed;
        lensData.sig = DataTypes.EIP712Signature(
            sig.v,
            sig.r,
            sig.s,
            sig.deadline
        );
        _mirrorWithSign(lensData);
        _loan(content.bidToken, content.bidAmount);
        _contentByIndex[index].state = DataTypes.AuditState.Pass;
    }

    function auditBidComment(
        uint256 index,
        uint256 profileId,
        DataTypes.EIP712Signature calldata sig
    ) external {
        _validateContentIndex(index);
        Content memory content = _contentByIndex[index];
        if (content.bidType != BidType.Comment) {
            revert Errors.ParamsrInvalid();
        }
        if (content.state != DataTypes.AuditState.Pending) {
            revert Errors.BidIsClose();
        }
        _validateExpires(content.bidExpires);
        _validateProfile(profileId, content.toProfiles);
        ILensHub.CommentWithSigData memory lensData;
        lensData.profileId = profileId;
        lensData.profileIdPointed = content.profileIdPointed;
        lensData.pubIdPointed = content.pubIdPointed;
        lensData.sig = DataTypes.EIP712Signature(
            sig.v,
            sig.r,
            sig.s,
            sig.deadline
        );
        _commentWithSign(lensData);
        _loan(content.bidToken, content.bidAmount);
        _contentByIndex[index].state = DataTypes.AuditState.Pass;
    }

    function loanWithSig(
        uint256 index,
        uint256 profileId,
        address relayer,
        DataTypes.EIP712Signature calldata sig
    ) external {
        _validateMomokaContentIndex(index);
        if (!_relayerWhitelisted[relayer]) {
            revert Errors.NotWhitelisted();
        }
        MomokaContent memory content = _momokaContentByIndex[index];
        if (content.state != DataTypes.AuditState.Pending) {
            revert Errors.BidIsClose();
        }
        _validateProfile(profileId, content.toProfiles);
        SigUtils._validateRecoveredAddress(
            SigUtils._calculateDigest(
                keccak256(
                    abi.encode(
                        LOAN_WITH_SIG_TYPEHASH,
                        index,
                        _msgSender(),
                        sig.deadline
                    )
                ),
                name
            ),
            relayer,
            sig
        );
        _loan(content.bidToken, content.bidAmount);
        _momokaContentByIndex[index].state = DataTypes.AuditState.Pass;
    }

    // View
    function getMinBidAmount(
        address wallet,
        address token
    ) external view returns (uint256) {
        return _minBidByTokenByWallet[wallet][token];
    }

    function isBidTokenWhitelisted(address token) external view returns (bool) {
        return _bidTokenWhitelisted[token];
    }

    function getContentByIndex(
        uint256 index
    ) external view returns (Content memory) {
        return _contentByIndex[index];
    }

    function getMomokaContentByIndex(
        uint256 index
    ) external view returns (MomokaContent memory) {
        return _momokaContentByIndex[index];
    }

    function getBidCounter() external view returns (uint256) {
        return _bidCounter;
    }

    function getMomokaBidCunter() external view returns (uint256) {
        return _momokaBidCounter;
    }

    // Private
    function _validateExpires(uint256 expires) internal view {
        if (expires < block.timestamp) {
            revert Errors.Expired();
        }
    }

    function _validateContentIndex(uint256 index) internal view {
        if (index > _bidCounter) {
            revert Errors.ParamsrInvalid();
        }
    }

    function _validateMomokaContentIndex(uint256 index) internal view {
        if (index > _momokaBidCounter) {
            revert Errors.ParamsrInvalid();
        }
    }

    function _validateBidAndGetToken(
        address token,
        uint256 amount,
        BidType bidType,
        uint256[] memory toProfiles
    ) internal {
        if (toProfiles.length > maxToProfileCounter) {
            revert Errors.ToProfileLimitExceeded();
        }
        for (uint8 i = 0; i < toProfiles.length; i++) {
            address profileOwner = ILensHub(LENS_HUB).ownerOf(toProfiles[i]);
            if (_minBidByTokenByWallet[profileOwner][token] > amount) {
                revert Errors.NotReachedMinimum();
            }
            if (_disableAuditType[profileOwner][bidType]) {
                revert Errors.BidTypeNotAccept();
            }
        }
        if (token == address(0) && amount != msg.value) {
            revert Errors.InsufficientInputAmount();
        }
        if (token != address(0)) {
            if (!_bidTokenWhitelisted[token])
                revert Errors.BidTokenNotWhitelisted();
            IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
        }
    }

    function _validateProfile(
        uint256 profileId,
        uint256[] memory toProfiles
    ) internal {
        address profileOwner = ILensHub(LENS_HUB).ownerOf(profileId);
        bool flag;
        if (profileOwner != _msgSender()) {
            revert Errors.NotProfileOwner();
        }
        for (uint8 i = 0; i < toProfiles.length; i++) {
            if (toProfiles[i] == profileId) {
                flag = true;
                break;
            }
        }
        if (toProfiles.length == 0) {
            flag = true;
        }
        if (!flag) {
            revert Errors.NotAuditor();
        }
    }

    function _setMinBid(address token, uint256 min) internal {
        _minBidByTokenByWallet[_msgSender()][token] = min;
    }

    function _setDisableAuditTypes(bool[] calldata disableAuditTypes) internal {
        if (disableAuditTypes.length != 3) {
            revert Errors.ParamsrInvalid();
        }
        _disableAuditType[_msgSender()][BidType.Post] = disableAuditTypes[0];
        _disableAuditType[_msgSender()][BidType.Comment] = disableAuditTypes[1];
        _disableAuditType[_msgSender()][BidType.Mirror] = disableAuditTypes[2];
    }

    function _postWithSign(ILensHub.PostWithSigData memory vars) internal {
        ILensHub(LENS_HUB).postWithSig(vars);
    }

    function _mirrorWithSign(ILensHub.MirrorWithSigData memory vars) internal {
        ILensHub(LENS_HUB).mirrorWithSig(vars);
    }

    function _commentWithSign(
        ILensHub.CommentWithSigData memory vars
    ) internal {
        ILensHub(LENS_HUB).commentWithSig((vars));
    }

    function _bid(BidData calldata vars, BidType bidType) internal {
        _validateBidAndGetToken(
            vars.bidToken,
            vars.bidAmount,
            bidType,
            vars.toProfiles
        );
        uint256 counter = ++_bidCounter;
        Content memory content;
        content.contentURI = vars.contentURI;
        content.bidAmount = vars.bidAmount;
        content.bidToken = vars.bidToken;
        content.bidAmount = vars.bidAmount;
        content.bidAddress = _msgSender();
        content.bidExpires = block.timestamp + vars.duration;
        content.toProfiles = vars.toProfiles;
        content.bidType = bidType;
        if (bidType == BidType.Comment || bidType == BidType.Mirror) {
            content.profileIdPointed = vars.profileIdPointed;
            content.pubIdPointed = vars.pubIdPointed;
        }
        content.state = DataTypes.AuditState.Pending;
        _contentByIndex[counter] = content;
    }

    function _bidMomoka(MomokaBidData calldata vars, BidType bidType) internal {
        _validateBidAndGetToken(
            vars.bidToken,
            vars.bidAmount,
            bidType,
            vars.toProfiles
        );
        uint256 counter = ++_momokaBidCounter;
        MomokaContent memory content;
        content.bidAmount = vars.bidAmount;
        content.bidToken = vars.bidToken;
        content.bidAmount = vars.bidAmount;
        content.bidAddress = _msgSender();
        content.bidExpires = block.timestamp + vars.duration;
        content.toProfiles = vars.toProfiles;
        content.bidType = bidType;
        if (bidType == BidType.Post) {
            content.contentURI = vars.contentURI;
        }
        if (bidType == BidType.Comment) {
            content.contentURI = vars.contentURI;
            content.commentOn = vars.commentOn;
        }
        if (bidType == BidType.Mirror) {
            content.mirror = vars.mirror;
        }
        content.state = DataTypes.AuditState.Pending;
        _momokaContentByIndex[counter] = content;
    }

    function _cancelBid(uint256 index) internal {
        _validateContentIndex(index);
        Content memory content = _contentByIndex[index];
        if (content.bidAddress != _msgSender()) revert Errors.NotBidder();
        if (content.bidExpires > block.timestamp) revert Errors.NotExpired();
        if (content.state != DataTypes.AuditState.Pending)
            revert Errors.BidIsClose();
        if (content.bidAmount > 0) {
            _sendTokenOrETH(
                content.bidToken,
                content.bidAddress,
                content.bidAmount
            );
        }
        _contentByIndex[index].state = DataTypes.AuditState.Cancel;
    }

    function _cancelBidMomoka(uint256 index) internal {
        _validateMomokaContentIndex(index);
        (index);
        MomokaContent memory content = _momokaContentByIndex[index];
        if (content.bidAddress != _msgSender()) revert Errors.NotBidder();
        if (content.bidExpires > block.timestamp) revert Errors.NotExpired();
        if (content.state != DataTypes.AuditState.Pending)
            revert Errors.BidIsClose();
        if (content.bidAmount > 0) {
            _sendTokenOrETH(
                content.bidToken,
                content.bidAddress,
                content.bidAmount
            );
        }
        _momokaContentByIndex[index].state = DataTypes.AuditState.Cancel;
    }

    function _loan(address token, uint256 amount) internal {
        uint256 feeAmount = amount.mul(feeRate).div(FEE_DENOMINATOR);
        _sendTokenOrETH(token, feeCollector, feeAmount);
        _sendTokenOrETH(token, _msgSender(), amount.sub(feeAmount));
    }

    function _sendTokenOrETH(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            _sendETH(to, amount);
        } else {
            _sendToken(token, to, amount);
        }
    }

    function _sendToken(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}(new bytes(0));
        if (!success) revert Errors.ETHTransferFailed();
    }
}
