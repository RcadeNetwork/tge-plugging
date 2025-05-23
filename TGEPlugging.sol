// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./INFTPlugging.sol";

contract TGEPlugging is
    Initializable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // Events
    event Plugged(
        address indexed user,
        address indexed collection,
        uint256[] tokenIds,
        uint256 pluggedAt
    );
    event Unplugged(
        address indexed user,
        address indexed collection,
        uint256[] tokenIds,
        uint256 unpluggedAt
    );
    event TreasuryAddressUpdated(
        address indexed oldTreasury,
        address indexed newTreasury,
        uint256 timestamp,
        address initiatedBy
    );
    event MaxTokenIdsLengthUpdated(
        uint oldLength,
        uint newLength,
        uint256 timestamp,
        address initiatedBy
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner,
        uint256 timestamp,
        address initiatedBy
    );
    
    event ExtendedAllNFTs(
        address indexed user,
        uint256 timestamp
    );

    event PluggedTimeExtended(
        address indexed user,
        address indexed collection,
        uint256[] tokenIds,
        uint256 timestamp
    );

    event PlugDurationUpdated(
        uint oldDuration,
        uint newDuration,
        uint256 timestamp,
        address indexed initiatedBy
    );

    event PluggingDeadlineUpdated(
        uint oldDeadline,
        uint newDeadline,
        uint256 timestamp,
        address indexed initiatedBy
    );

    struct PlugDetails {
        address owner;
        uint256 pluggedAt;
    }

    IERC721Upgradeable public _nexusGem;
    IERC721Upgradeable public _rgBytes;
    IERC721Upgradeable public _immortals;

    INFTPlugging public _nftPluggingContract;

    uint public _maxTokenIdsLength;
    uint public _plugDurationSecs;
    uint public _pluggingDeadline;

    address public _treasury;

    mapping(uint256 tokenId => PlugDetails) public _nexusGemsPlugDetails;
    mapping(uint256 tokenId => PlugDetails) public _rgBytesPlugDetails;
    mapping(uint256 tokenId => PlugDetails) public _immortalsPlugDetails;

    mapping(address user => uint256 timestamp) public _extendedAt; // Tracks last extension time for each user

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address nexusGem,
        address rgBytes,
        address immortals,
        address admin,
        address treasury,
        uint plugDurationSecs,
        address nftPluggingContract,
        uint pluggingDeadline
    ) public initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _isValidAddress(nexusGem);
        _isValidAddress(rgBytes);
        _isValidAddress(immortals);
        _isValidAddress(treasury);
        _isValidAddress(nftPluggingContract);

        _nexusGem = IERC721Upgradeable(nexusGem);
        _rgBytes = IERC721Upgradeable(rgBytes);
        _immortals = IERC721Upgradeable(immortals);
        _nftPluggingContract = INFTPlugging(nftPluggingContract);

        _maxTokenIdsLength = 75;
        _treasury = treasury;
        _plugDurationSecs = plugDurationSecs;
        _pluggingDeadline = pluggingDeadline;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function plug(
        address collectionAddress,
        uint256[] calldata tokenIds
    ) external nonReentrant whenNotPaused {
        _isValidColllectionAddress(collectionAddress);
        _isValidTokenIdsArray(tokenIds);
        IERC721Upgradeable nftContract = IERC721Upgradeable(collectionAddress);

        uint256 currentTimestamp = block.timestamp;

        require(currentTimestamp <= _pluggingDeadline, "TGEPlugging: Cannot plug after deadline");

        for (uint i; i < tokenIds.length; i++) {
            require(
                nftContract.ownerOf(tokenIds[i]) == msg.sender,
                "TGEPlugging: You don't own all token"
            );

            _setPlugDetails(
                collectionAddress,
                tokenIds[i],
                PlugDetails(msg.sender, currentTimestamp)
            );
            nftContract.transferFrom(msg.sender, _treasury, tokenIds[i]);
        }
        emit Plugged(msg.sender, collectionAddress, tokenIds, currentTimestamp);
    }

    function unplug(
        address collectionAddress,
        uint256[] calldata tokenIds
    ) external nonReentrant whenNotPaused {
        _isValidColllectionAddress(collectionAddress);
        _isValidTokenIdsArray(tokenIds);

        uint256 currentTimestamp = block.timestamp;
        uint256 extendedAt = _extendedAt[msg.sender];

        // triggered in case of extendAll
        if (extendedAt > 0) {
            require(
                currentTimestamp >= extendedAt + _plugDurationSecs,
                "TGEPlugging: Cannot unplug before extended duration"
            );
        }

        for (uint256 i; i < tokenIds.length; i++) {
            PlugDetails memory plugDetails = _getPlugDetails(
                collectionAddress,
                tokenIds[i]
            );

            if (plugDetails.owner == msg.sender) {
                // token is plugged in current contract
                require(
                    currentTimestamp >=
                        plugDetails.pluggedAt + _plugDurationSecs,
                    "TGEPlugging: Cannot unplug before valid duration"
                );

                _deletePlugDetails(collectionAddress, tokenIds[i]);

                IERC721Upgradeable(collectionAddress).transferFrom(
                    _treasury,
                    msg.sender,
                    tokenIds[i]
                );
            } else {
                // Only fetch old contract data if needed
                uint[]
                    memory pluggedTokenIdsInOldContract = _nftPluggingContract
                        .getUserPluggedTokenIds(collectionAddress, msg.sender);

                if (
                    _checkValueExistsInArray(
                        pluggedTokenIdsInOldContract,
                        tokenIds[i]
                    )
                ) {
                    // token is plugged in old contract
                    _nftPluggingContract.removePluggedDetails(
                        msg.sender,
                        collectionAddress,
                        tokenIds[i]
                    );

                    IERC721Upgradeable(collectionAddress).transferFrom(
                        _treasury,
                        msg.sender,
                        tokenIds[i]
                    );
                } else {
                    // token is not plugged in any contract
                    revert("TGEPlugging: Token is not plugged in any contract");
                }
            }
        }

        emit Unplugged(
            msg.sender,
            collectionAddress,
            tokenIds,
            currentTimestamp
        );
    }

    function extendAll() external whenNotPaused nonReentrant {
        uint256 currentTimestamp = block.timestamp;

        require(
            currentTimestamp >= _extendedAt[msg.sender] + _plugDurationSecs,
            "TGEPlugging: Cannot extend again yet"
        );

        _extendedAt[msg.sender] = currentTimestamp;

        emit ExtendedAllNFTs(msg.sender, currentTimestamp);
    }

    function extendPluggedTime(
        address collectionAddress,
        uint256[] memory tokenIds
    ) external nonReentrant whenNotPaused {
        _isValidColllectionAddress(collectionAddress);
        _isValidTokenIdsArray(tokenIds);

        uint256 currentTimestamp = block.timestamp;
        uint256 extendedAt = _extendedAt[msg.sender];

        require(
            currentTimestamp >= extendedAt + _plugDurationSecs,
            "TGEPlugging: Cannot extend again yet"
        );

        for (uint i; i < tokenIds.length; i++) {
            PlugDetails memory plugDetails = _getPlugDetails(
                collectionAddress,
                tokenIds[i]
            );
            
            require(currentTimestamp > plugDetails.pluggedAt + _plugDurationSecs, "TGEPlugging: Cannot extend before valid plug duration");
            
            if (plugDetails.owner == msg.sender) {
                // Token is plugged in current contract
                _setPlugDetails(
                    collectionAddress,
                    tokenIds[i],
                    PlugDetails(msg.sender, currentTimestamp)
                );
            } else {
                // Only fetch old contract data if needed
                uint[]
                    memory pluggedTokenIdsInOldContract = _nftPluggingContract
                        .getUserPluggedTokenIds(collectionAddress, msg.sender);

                if (
                    _checkValueExistsInArray(
                        pluggedTokenIdsInOldContract,
                        tokenIds[i]
                    )
                ) {
                    // Token is plugged in old contract
                    _setPlugDetails(
                        collectionAddress,
                        tokenIds[i],
                        PlugDetails(msg.sender, currentTimestamp)
                    );

                    _nftPluggingContract.removePluggedDetails(
                        msg.sender,
                        collectionAddress,
                        tokenIds[i]
                    );
                } else {
                    revert("TGEPlugging: Token is not plugged in any contract");
                }
            }
        }

        emit PluggedTimeExtended(
            msg.sender,
            collectionAddress,
            tokenIds,
            currentTimestamp
        );
    }

    function updateTreasuryAddress(
        address treasury
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _isValidAddress(treasury);
        address oldTreasury = _treasury;
        _treasury = treasury;
        emit TreasuryAddressUpdated(
            oldTreasury,
            treasury,
            block.timestamp,
            msg.sender
        );
    }

    function updateMaxTokenIdsLength(
        uint length
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(length > 0, "TGEPlugging: Invalid array length");
        uint oldLength = _maxTokenIdsLength;
        _maxTokenIdsLength = length;
        emit MaxTokenIdsLengthUpdated(
            oldLength,
            length,
            block.timestamp,
            msg.sender
        );
    }

    function updatePlugDuration(
        uint plugDuration
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(plugDuration > 0, "TGEPlugging: Invalid plug duration");
        uint oldDuration = _plugDurationSecs;
        _plugDurationSecs = plugDuration;
        emit PlugDurationUpdated(
            oldDuration,
            plugDuration,
            block.timestamp,
            msg.sender
        );
    }

    function updatePluggingDeadline(
        uint pluggingDeadline
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        require(pluggingDeadline > 0, "TGEPlugging: Invalid plugging deadline");
        uint oldDeadline = _pluggingDeadline;
        _pluggingDeadline = pluggingDeadline;
        emit PluggingDeadlineUpdated(
            oldDeadline,
            pluggingDeadline,
            block.timestamp,
            msg.sender
        );
    }

    function updateNftPluggingContract(
        address nftPluggingContract
    ) public onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        _isValidAddress(nftPluggingContract);
        _nftPluggingContract = INFTPlugging(nftPluggingContract);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function transferContractOwnership(
        address newOwner
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidAddress(newOwner);

        address oldOwner = msg.sender;

        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _revokeRole(PAUSER_ROLE, msg.sender);
        _revokeRole(UPGRADER_ROLE, msg.sender);

        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _grantRole(PAUSER_ROLE, newOwner);
        _grantRole(UPGRADER_ROLE, newOwner);

        emit OwnershipTransferred(
            oldOwner,
            newOwner,
            block.timestamp,
            msg.sender
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    function _checkValueExistsInArray(
        uint[] memory array,
        uint value
    ) private pure returns (bool) {
        for (uint i; i < array.length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }

    function _isValidColllectionAddress(address addr) private view {
        require(
            addr == address(_immortals) ||
                addr == address(_rgBytes) ||
                addr == address(_nexusGem),
            "TGEPlugging: Invalid collection address"
        );
    }

    function _isValidContractAddress(address addr) private view {
        require(addr.code.length > 0, "TGEPlugging: Invalid contract address");
    }

    function _isValidAddress(address addr) private pure {
        require(addr != address(0), "TGEPlugging: Invalid address");
    }

    function _isValidTokenIdsArray(uint[] memory tokenIds) private view {
        require(
            tokenIds.length <= _maxTokenIdsLength,
            "TGEPlugging: TokenIds array <= max allowed length"
        );
    }

    function _getPlugDetails(
        address collection,
        uint256 tokenId
    ) internal view returns (PlugDetails memory) {
        if (collection == address(_nexusGem)) {
            return _nexusGemsPlugDetails[tokenId];
        } else if (collection == address(_rgBytes)) {
            return _rgBytesPlugDetails[tokenId];
        } else if (collection == address(_immortals)) {
            return _immortalsPlugDetails[tokenId];
        }
        revert("Invalid collection");
    }

    function _setPlugDetails(
        address collection,
        uint256 tokenId,
        PlugDetails memory details
    ) internal {
        if (collection == address(_nexusGem)) {
            _nexusGemsPlugDetails[tokenId] = details;
        } else if (collection == address(_rgBytes)) {
            _rgBytesPlugDetails[tokenId] = details;
        } else if (collection == address(_immortals)) {
            _immortalsPlugDetails[tokenId] = details;
        } else {
            revert("Invalid collection");
        }
    }

    function _deletePlugDetails(address collection, uint256 tokenId) internal {
        if (collection == address(_nexusGem)) {
            delete _nexusGemsPlugDetails[tokenId];
        } else if (collection == address(_rgBytes)) {
            delete _rgBytesPlugDetails[tokenId];
        } else if (collection == address(_immortals)) {
            delete _immortalsPlugDetails[tokenId];
        } else {
            revert("Invalid collection");
        }
    }
}
