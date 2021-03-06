// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "@openzeppelin/contracts/presets/ERC721PresetMinterPauserAutoId.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/ERC998/IERC998ERC20TopDown.sol";
import "./ERC998/ERC998ERC721BottomUp.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract DBol is
    ERC721PresetMinterPauserAutoId,
    ERC998ERC721BottomUp,
    IERC998ERC20TopDown
{
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Keeps track of all the tokens which a tokenId owns
    mapping(uint256 => EnumerableSet.AddressSet) erc20Contracts;

    /// @dev index of a contract inside of erc20Contracts set
    mapping(uint256 => mapping(address => uint256)) erc20ContractIndex;

    /// @dev tokenId balance for contract
    mapping(uint256 => mapping(address => uint256)) erc20Balances;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_
    ) public ERC721PresetMinterPauserAutoId(name_, symbol_, baseURI_) {}

    /// @dev Wrapper around the ERC721 mint function to create a new token
    /// @dev this function will only work if the msg.sender has the minter role
    /// @dev must call grantRole first to assign permission
    function createDBol(uint256 _parentTokenId) public returns (uint256) {
        require(Address.isContract(msg.sender));
        // mint a ERC721 token
        mint(msg.sender);
        tokenIdToTokenOwner[totalSupply() - 1] = TokenOwner(
            msg.sender,
            _parentTokenId
        );
        return totalSupply() - 1;
    }

    ////////////////////// Iplementation of ERC998ERC20TopDown.sol below ///////////////////

    /// @notice A token receives ERC20 tokens
    /// @param _from The prior owner of the ERC20 tokens
    /// @param _value The number of ERC20 tokens received
    /// @param _data Up to the first 32 bytes contains an integer which is the receiving tokenId.
    function tokenFallback(
        address _from,
        uint256 _value,
        bytes calldata _data
    ) external override {
        require(Address.isContract(msg.sender));
        require(_data.length > 0, "must contain uint256 tokenId");
        uint256 tokenId;
        // Already prety succinct so keeping the assembly code
        assembly {
            tokenId := calldataload(132)
        }
        if (_data.length < 32) {
            tokenId = tokenId >> (256 - _data.length * 8);
        }

        // if the token doesn't already have this contract in it's set
        if (!erc20Contracts[tokenId].contains(msg.sender)) {
            erc20Contracts[tokenId].add(msg.sender);
            erc20ContractIndex[tokenId][msg.sender] = erc20Contracts[tokenId]
                .length();
        }
        // update the balance
        erc20Balances[tokenId][msg.sender] = erc20Balances[tokenId][msg.sender]
            .add(_value);

        ReceivedERC20(_from, tokenId, msg.sender, _value);
    }

    /// @notice Look up the balance of ERC20 tokens for a specific token and ERC20 contract
    /// @param _tokenId The token that owns the ERC20 tokens
    /// @param _erc20Contract The ERC20 contract
    /// @return The number of ERC20 tokens owned by a token from an ERC20 contract
    function _balanceOfERC20(uint256 _tokenId, address _erc20Contract)
        internal
        view
        returns (uint256)
    {
        return erc20Balances[_tokenId][_erc20Contract];
    }

    /// @notice Look up the balance of ERC20 tokens for a specific token and ERC20 contract
    /// @param _tokenId The token that owns the ERC20 tokens
    /// @param _erc20Contract The ERC20 contract
    /// @return The number of ERC20 tokens owned by a token from an ERC20 contract
    function balanceOfERC20(uint256 _tokenId, address _erc20Contract)
        external
        view
        override
        returns (uint256)
    {
        return _balanceOfERC20(_tokenId, _erc20Contract);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Transfer ERC20 tokens to address
    /// @param _tokenId The token to transfer from
    /// @param _to The address to send the ERC20 tokens to
    /// @param _erc20Contract The ERC20 contract
    /// @param _value The number of ERC20 tokens to transfer
    function transferERC20(
        uint256 _tokenId,
        address _to,
        address _erc20Contract,
        uint256 _value
    ) external override {
        require(_to != address(0)); // can't burn the tokens
        address rootOwner =
            address(uint256(_rootOwnerOf(_tokenId) & ADDRESS_MASK));
        require(
            rootOwner == msg.sender ||
                tokenOwnerToOperators[rootOwner][msg.sender] ||
                rootOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] ==
                msg.sender
        ); // must have the right permissions
        require(erc20Balances[_tokenId][_erc20Contract] >= _value); // must have enough tokens
        // decrease the balance the _tokenId has of _erc20Contract by _value
        erc20Balances[_tokenId][_erc20Contract] = erc20Balances[_tokenId][
            _erc20Contract
        ]
            .sub(_value);
        // if the balance of _erc20Contract is now 0
        if (erc20Balances[_tokenId][_erc20Contract] == 0) {
            // remove the contract from set of contracts
            erc20Contracts[_tokenId].remove(_erc20Contract);
            // delete the value held in the index mapping
            delete erc20ContractIndex[_tokenId][_erc20Contract];
        }
        require(
            IERC20(_erc20Contract).transfer(_to, _value),
            "ERC20 transfer failed"
        );
        emit TransferERC20(_tokenId, _to, _erc20Contract, _value);
    }

    /// @notice Transfer ERC20 tokens to address or ERC20 top-down composable
    /// @param _tokenId The token to transfer from
    /// @param _to The address to send the ERC20 tokens to
    /// @param _erc223Contract The ERC223 token contract
    /// @param _value The number of ERC20 tokens to transfer
    /// @param _data Additional data with no specified format, can be used to specify tokenId to transfer to
    function transferERC223(
        uint256 _tokenId,
        address _to,
        address _erc223Contract,
        uint256 _value,
        bytes calldata _data
    ) external override {
        require(_to != address(0)); // can't burn the tokens
        address rootOwner =
            address(uint256(_rootOwnerOf(_tokenId) & ADDRESS_MASK));
        require(
            rootOwner == msg.sender ||
                tokenOwnerToOperators[rootOwner][msg.sender] ||
                rootOwnerAndTokenIdToApprovedAddress[rootOwner][_tokenId] ==
                msg.sender
        ); // must have the right permissions
        require(erc20Balances[_tokenId][_erc223Contract] >= _value); // must have enough tokens
        // decrease the balance the _tokenId has of _erc20Contract by _value
        erc20Balances[_tokenId][_erc223Contract] = erc20Balances[_tokenId][
            _erc223Contract
        ]
            .sub(_value);
        // if the balance of _erc20Contract is now 0
        if (erc20Balances[_tokenId][_erc223Contract] == 0) {
            // remove the contract from set of contracts
            erc20Contracts[_tokenId].remove(_erc223Contract);
            // delete the value held in the index mapping
            delete erc20ContractIndex[_tokenId][_erc223Contract];
        }
        require(
            IERC20(_erc223Contract).transfer(_to, _value),
            "ERC20 transfer failed"
        );
        emit TransferERC20(_tokenId, _to, _erc223Contract, _value);
    }

    /// @notice Get ERC20 tokens from ERC20 contract.
    /// @dev Needs to be approved first by the _erc20Contract
    /// @param _from The current owner address of the ERC20 tokens that are being transferred.
    /// @param _tokenId The token to transfer the ERC20 tokens to.
    /// @param _erc20Contract The ERC20 token contract
    /// @param _value The number of ERC20 tokens to transfer
    function getERC20(
        address _from,
        uint256 _tokenId,
        address _erc20Contract,
        uint256 _value
    ) external override {
        require(
            IERC20(_erc20Contract).allowance(_from, address(this)) >= _value
        );
        require(
            IERC20(_erc20Contract).transferFrom(_from, address(this), _value)
        );
        // if the token doesn't already have this contract in it's set
        if (!erc20Contracts[_tokenId].contains(_erc20Contract)) {
            erc20Contracts[_tokenId].add(_erc20Contract);
            erc20ContractIndex[_tokenId][_erc20Contract] = erc20Contracts[
                _tokenId
            ]
                .length();
        }
        // update the balance
        erc20Balances[_tokenId][_erc20Contract] = erc20Balances[_tokenId][
            msg.sender
        ]
            .add(_value);
        ReceivedERC20(_from, _tokenId, _erc20Contract, _value);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override(ERC721, ERC721Pausable) {
        super._beforeTokenTransfer(from, to, tokenId);
        require(to != address(0)); // disallow burning
    }
}
