// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ECDSA} from "openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "openzeppelin-latest/contracts/utils/Nonces.sol";

import {IdRegistry} from "./IdRegistry.sol";
import {Signatures} from "./lib/Signatures.sol";
import {TrustedCaller} from "./lib/TrustedCaller.sol";

contract KeyRegistry is TrustedCaller, Signatures, EIP712, Nonces {
    /**
     *  @notice State enumeration for a key in the registry. During migration, an admin can change
     *          the state of any fids key from NULL to ADDED or ADDED to NULL. After migration, an
     *          fid can change the state of a key from NULL to ADDED or ADDED to REMOVED only.
     *
     *          - NULL: The key is not in the registry.
     *          - ADDED: The key has been added to the registry.
     *          - REMOVED: The key was added to the registry, but is now removed.
     */
    enum KeyState {
        NULL,
        ADDED,
        REMOVED
    }

    /**
     *  @notice Data about a key.
     *
     *  @param state   The current state of the key.
     *  @param scheme  The manner in which the key should be used.
     */
    struct KeyData {
        KeyState state;
        uint32 scheme;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Revert if a key violates KeyState transition rules.
    error InvalidState();

    /// @dev Revert if the caller does not have the authority to perform the action.
    error Unauthorized();

    /// @dev Revert if owner calls migrateKeys more than once.
    error AlreadyMigrated();

    /// @dev Revert if migration batch input arrays are not the same length.
    error InvalidBatchInput();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Emit an event when an admin or fid adds a new key.
     *
     *      Hubs listen for this, validate that keyBytes is an EdDSA pub key and scheme == 1 and
     *      add keyBytes to its SignerStore. Messages signed by keyBytes with `fid` are now valid
     *      and accepted over gossip, sync and client apis. Hubs assume the invariants:
     *
     *      1. Add(fid, ..., key, keyBytes, ...) cannot emit if there is an earlier emit with
     *         Add(fid, ..., key, keyBytes, ...)
     *
     *      2. Add(fid, ..., key, keyBytes, ...) cannot emit if there is an earlier emit with
     *         Remove(fid, key, keyBytes)
     *
     *      3. For all Add(..., ..., key, keyBytes, ...) key = keccack(keyBytes)
     *
     * @param fid       The fid associated with the key.
     * @param scheme    The type of the key.
     * @param key       The key being registered. (indexed as hash)
     * @param keyBytes  The bytes of the key being registered.
     * @param metadata  Metadata about the key.
     */
    event Add(uint256 indexed fid, uint32 indexed scheme, bytes indexed key, bytes keyBytes, bytes metadata);

    /**
     * @dev Emit an event when an fid removes an added key.
     *
     *      Hubs listen for this, validate that keyBytes is an EdDSA pub key, that scheme == 1 and
     *      that keyBytes exists in its SignerStore.  keyBytes is marked as removed, messages signed
     *      by keyBytes with `fid` areinvalid, dropped immediately and no longer accepted. Hubs
     *      assume the invariants:
     *
     *      1. Remove(fid, key, keyBytes cannot emit if there is no earlier emit with
     *         Add(fid, ..., key, keyBytes, ...)
     *
     *      2. Remove(fid, key, keyBytes, ...) cannot emit if there is an earlier emit with
     *         Remove(fid, key, keyBytes)
     *
     *      3. For all Remove(..., key, keyBytes), key = keccack(keyBytes)
     *
     * @param fid       The fid associated with the key.
     * @param key       The key being registered. (indexed as hash)
     * @param keyBytes  The bytes of the key being registered.
     */
    event Remove(uint256 indexed fid, bytes indexed key, bytes keyBytes);

    /**
     * @dev Emit an event when an admin resets an added key.
     *
     *      Hubs listen for this, validate that keyBytes is an EdDSA pub key, that scheme == 1 and
     *      that keyBytes exists in its SignerStore. keyBytes is no longer tracked, messages signed
     *      by keyBytes with `fid` are invalid, dropped immediately and not accepted. Unlike Remove
     *      keyBytes can be added to the SignerStore if an Add() event is observed.
     *
     * @param fid       The fid associated with the key.
     * @param key       The key being reset. (indexed as hash)
     * @param keyBytes  The bytes of the key being registered.
     */
    event AdminReset(uint256 indexed fid, bytes indexed key, bytes keyBytes);

    /**
     * @dev Emit an event when the admin calls migrateKeys. Used to migrate Hubs from using
     *      off-chain signers to on-chain signers.
     *
     *      Hubs listen for this and:
     *      1. Stop accepting Farcaster Signer messages with a timestamp >= keysMigratedAt.
     *      2. After grace period (24 hours), stop accepting all Farcaster Signer messages.
     *      3. Drop any messages created by off-chain Farcaster Signers whose pub key was
     *         not emitted as an Add event.
     *
     *      If SignerMessages are not correctly migrated by an admin during the migration,
     *      there is a chance that there is some data loss, which is considered an acceptable
     *      risk for this migration.
     *
     *      If this event is emitted incorrectly ahead of schedule, new users could not post
     *      and existing users could not add new apps. A protocol upgrade will be necessary
     *      which could take up to 6 weeks to roll out correctly.
     *
     * @param keysMigratedAt  The timestamp at which the migration occurred.
     */
    event Migrated(uint256 indexed keysMigratedAt);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant _ADD_TYPEHASH =
        keccak256("Add(address owner,uint32 scheme,bytes key,bytes metadata,uint256 nonce,uint256 deadline)");

    bytes32 internal constant _REMOVE_TYPEHASH =
        keccak256("Remove(address owner,bytes key,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The IdRegistry contract.
     */
    IdRegistry public immutable idRegistry;

    /**
     * @dev Period in seconds after migration during which admin can bulk add/reset keys.
     *      Admins can make corrections to the migrated data during the grace period if necessary,
     *      but cannot make changes after it expires.
     */
    uint24 public immutable gracePeriod;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Timestamp at which keys migrated. Hubs will cut over to use this key registry as their
     *      source of truth after this timestamp.
     */
    uint40 public keysMigratedAt;

    /**
     * @dev Mapping of fid to a key to the key's metadata.
     *
     * @custom:param fid       The fid associated with the key.
     * @custom:param key       Bytes of the key.
     * @custom:param data      Struct with the state and key type. In the initial migration
     *                         all keys will have data.scheme == 1.
     */
    mapping(uint256 fid => mapping(bytes key => KeyData data)) public keys;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the IdRegistry, migration grace period, and owner.
     *
     * @param _idRegistry  IdRegistry contract address. Immutable.
     * @param _gracePeriod Migration grace period in seconds. Immutable.
     * @param _owner       Contract owner address.
     */
    constructor(
        address _idRegistry,
        uint24 _gracePeriod,
        address _owner
    ) TrustedCaller(_owner) EIP712("Farcaster KeyRegistry", "1") {
        gracePeriod = _gracePeriod;
        idRegistry = IdRegistry(_idRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieve state and type data for a given key.
     *
     * @param fid   The fid associated with the key.
     * @param key   Bytes of the key.
     *
     * @return KeyData struct that contains the state and scheme.
     */
    function keyDataOf(uint256 fid, bytes calldata key) external view returns (KeyData memory) {
        return keys[fid][key];
    }

    /**
     * @notice Check if the contract has been migrated.
     *
     * @return true if the contract has been migrated, false otherwise.
     */
    function isMigrated() public view returns (bool) {
        return keysMigratedAt != 0;
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a key to the caller's fid, setting the key state to ADDED.
     *
     * @param scheme   The key's numeric scheme.
     * @param key      Bytes of the key to add.
     * @param metadata Metadata about the key, which is not stored and only emitted in an event.
     */
    function add(uint32 scheme, bytes calldata key, bytes calldata metadata) external {
        uint256 fid = idRegistry.idOf(msg.sender);
        if (fid == 0) revert Unauthorized();

        _add(fid, scheme, key, metadata);
    }

    function addFor(
        address owner,
        uint32 scheme,
        bytes calldata key,
        bytes calldata metadata,
        uint256 deadline,
        bytes calldata sig
    ) external {
        uint256 fid = idRegistry.idOf(owner);
        if (fid == 0) revert Unauthorized();

        _verifyAddSig(owner, scheme, key, metadata, deadline, sig);
        _add(fid, scheme, key, metadata);
    }

    function trustedAdd(
        address owner,
        uint32 scheme,
        bytes calldata key,
        bytes calldata metadata
    ) external onlyTrustedCaller {
        uint256 fid = idRegistry.idOf(owner);
        if (fid == 0) revert Unauthorized();

        _add(fid, scheme, key, metadata);
    }

    /**
     * @notice Remove a key associated with the caller's fid, setting the key state to REMOVED.
     *         The key must be in the ADDED state.
     *
     * @param key   Bytes of the key to remove.
     */
    function remove(bytes calldata key) external {
        uint256 fid = idRegistry.idOf(msg.sender);
        if (fid == 0) revert Unauthorized();

        _remove(fid, key);
    }

    function removeFor(address owner, bytes calldata key, uint256 deadline, bytes calldata sig) external {
        uint256 fid = idRegistry.idOf(owner);
        if (fid == 0) revert Unauthorized();

        _verifyRemoveSig(owner, key, deadline, sig);
        _remove(fid, key);
    }

    /*//////////////////////////////////////////////////////////////
                                MIGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the time of the key migration and emit an event. Hubs will watch this event and
     *         cut over to use the onchain registry as their source of truth after this timestamp.
     *         Only callable by the contract owner.
     */
    function migrateKeys() external onlyOwner {
        if (isMigrated()) revert AlreadyMigrated();
        keysMigratedAt = uint40(block.timestamp);
        emit Migrated(keysMigratedAt);
    }

    /**
     * @notice Add multiple keys as part of the initial migration. Only callable by the contract owner.
     *
     * @param fids    A list of fids to associate with keys.
     * @param fidKeys A list of public keys to register for each fid, in the same order as the fids array.
     */
    function bulkAddKeysForMigration(
        uint256[] calldata fids,
        bytes[][] calldata fidKeys,
        bytes calldata metadata
    ) external onlyOwner {
        if (isMigrated() && block.timestamp > keysMigratedAt + gracePeriod) revert Unauthorized();
        if (fids.length != fidKeys.length) revert InvalidBatchInput();

        // Safety: i and j can be incremented unchecked since they are bound by fids.length and
        // fidKeys[i].length respectively.
        unchecked {
            for (uint256 i = 0; i < fids.length; i++) {
                uint256 fid = fids[i];
                for (uint256 j = 0; j < fidKeys[i].length; j++) {
                    // TODO: add note about griefing during migration
                    _add(fid, 1, fidKeys[i][j], metadata);
                }
            }
        }
    }

    /**
     * @notice Reset multiple keys as part of the initial migration. Only callable by the contract owner.
     *         Reset is not the same as removal: this function sets the key state back to NULL,
     *         rather than REMOVED. This allows the owner to correct any errors in the initial migration until
     *         the grace period expires.
     *
     * @param fids    A list of fids whose added keys should be removed.
     * @param fidKeys A list of keys to remove for each fid, in the same order as the fids array.
     */
    function bulkResetKeysForMigration(uint256[] calldata fids, bytes[][] calldata fidKeys) external onlyOwner {
        if (isMigrated() && block.timestamp > keysMigratedAt + gracePeriod) revert Unauthorized();
        if (fids.length != fidKeys.length) revert InvalidBatchInput();

        // Safety: i and j can be incremented unchecked since they are bound by fids.length and
        // fidKeys[i].length respectively.
        unchecked {
            for (uint256 i = 0; i < fids.length; i++) {
                uint256 fid = fids[i];
                for (uint256 j = 0; j < fidKeys[i].length; j++) {
                    // TODO: add note about griefing during migration
                    _reset(fid, fidKeys[i][j]);
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _add(uint256 fid, uint32 scheme, bytes calldata key, bytes calldata metadata) internal {
        KeyData storage keyData = keys[fid][key];
        if (keyData.state != KeyState.NULL) revert InvalidState();

        keyData.state = KeyState.ADDED;
        keyData.scheme = scheme;
        emit Add(fid, scheme, key, key, metadata);
    }

    function _remove(uint256 fid, bytes calldata key) internal {
        KeyData storage keyData = keys[fid][key];
        if (keyData.state != KeyState.ADDED) revert InvalidState();

        keyData.state = KeyState.REMOVED;
        emit Remove(fid, key, key);
    }

    function _reset(uint256 fid, bytes calldata key) internal {
        KeyData storage keyData = keys[fid][key];
        if (keyData.state != KeyState.ADDED) revert InvalidState();

        keyData.state = KeyState.NULL;
        delete keyData.scheme;
        emit AdminReset(fid, key, key);
    }

    /*//////////////////////////////////////////////////////////////
                     SIGNATURE VERIFICATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _verifyAddSig(
        address owner,
        uint32 scheme,
        bytes memory key,
        bytes memory metadata,
        uint256 deadline,
        bytes memory sig
    ) internal {
        _verifySig(
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        _ADD_TYPEHASH, owner, scheme, keccak256(key), keccak256(metadata), _useNonce(owner), deadline
                    )
                )
            ),
            owner,
            deadline,
            sig
        );
    }

    function _verifyRemoveSig(address owner, bytes memory key, uint256 deadline, bytes memory sig) internal {
        _verifySig(
            _hashTypedDataV4(keccak256(abi.encode(_REMOVE_TYPEHASH, owner, keccak256(key), _useNonce(owner), deadline))),
            owner,
            deadline,
            sig
        );
    }
}
