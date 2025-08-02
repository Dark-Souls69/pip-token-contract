
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// --- INTERFACES ---

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

// --- UTILITY CONTRACTS ---

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

// --- BASE ERC20 CONTRACT ---

abstract contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view virtual override returns (string memory) { return _name; }
    function symbol() public view virtual override returns (string memory) { return _symbol; }
    function decimals() public pure virtual override returns (uint8) { return 18; }
    function totalSupply() public view virtual override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view virtual override returns (uint256) { return _balances[account]; }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _spendAllowance(sender, _msgSender(), amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        unchecked {
            _balances[sender] = senderBalance - amount;
            _balances[recipient] += amount;
        }
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
}

// --- MAIN PIP CONTRACT ---

contract PIP is ERC20 {
    address public immutable owner;
    bool public tradingEnabled = false;
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    mapping(address => bool) public isBlacklisted;
    uint256 public buyTaxPercent = 0;
    uint256 public sellTaxPercent = 0;
    bool public taxesEnabled = true;
    address public taxWallet;
    address public dexPair;
    mapping(address => bool) public isExcludedFromFees;
    uint256 public tokenPurchaseRate = 0;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TradingEnabled(bool enabled);
    event TaxesEnabledSet(bool enabled);
    event TaxRatesSet(uint256 buyTax, uint256 sellTax);
    event TaxWalletSet(address indexed wallet);
    event DexPairSet(address indexed pair);
    event TxLimitsSet(uint256 maxTx, uint256 maxWallet);
    event WalletBlacklistedStatusChanged(address indexed wallet, bool status);
    event FeeExclusionStatusChanged(address indexed account, bool isExcluded);
    event TokensPurchased(address indexed buyer, uint256 nativeAmount, uint256 tokenAmount);
    event TokensAirdropped(address indexed sender, uint256 totalAmount);
    event StuckTokensRecovered(address indexed tokenAddress, uint256 amount);
    event StuckNativeWithdrawn(uint256 amount);

    error PIP_NotOwner();
    error PIP_ZeroAddress();
    error PIP_Blacklisted();
    error PIP_TradingNotEnabled();
    error PIP_AmountLessThanTax();
    error PIP_MaxTxExceeded();
    error PIP_MaxWalletExceeded();
    error PIP_InsufficientBalance();
    error PIP_TaxTooHigh(uint256 maxAllowed);
    error PIP_MismatchedArrays();
    error PIP_CannotWithdrawOwnToken();
    error PIP_NoStuckTokens();
    error PIP_NativeTransferFailed();
    error PIP_RateNotSet();
    error PIP_InsufficientTokensForSale(uint256 available, uint256 requested);
    error PIP_EmptyRecipientsArray();
    error PIP_UnExcludeEssentialAddress();

    modifier onlyOwner() {
        if (_msgSender() != owner) revert PIP_NotOwner();
        _;
    }

    constructor() ERC20("Paws In Peace", "PIP") {
        owner = _msgSender();
        taxWallet = owner;
        _mint(owner, 5_000_000_000_000 * (10 ** decimals()));
        isExcludedFromFees[owner] = true;
        isExcludedFromFees[address(this)] = true;
        emit OwnershipTransferred(address(0), owner);
        emit TaxWalletSet(owner);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override(ERC20) {
        if (isBlacklisted[sender] || isBlacklisted[recipient]) revert PIP_Blacklisted();
        if (!tradingEnabled && !isExcludedFromFees[sender] && !isExcludedFromFees[recipient]) revert PIP_TradingNotEnabled();

        uint256 taxAmount = 0;
        if (taxesEnabled && dexPair != address(0)) {
            bool isBuyTransaction = (sender == dexPair);
            bool isSellTransaction = (recipient == dexPair);
            if (isBuyTransaction && buyTaxPercent > 0 && !isExcludedFromFees[recipient]) {
                taxAmount = (amount * buyTaxPercent) / 100;
            } else if (isSellTransaction && sellTaxPercent > 0 && !isExcludedFromFees[sender]) {
                taxAmount = (amount * sellTaxPercent) / 100;
            }
        }

        if (taxAmount > amount) revert PIP_AmountLessThanTax();
        uint256 transferAmount = amount - taxAmount;

        if (!isExcludedFromFees[recipient]) {
            if (maxTxAmount > 0 && amount > maxTxAmount) revert PIP_MaxTxExceeded();
            if (maxWalletAmount > 0 && balanceOf(recipient) + transferAmount > maxWalletAmount) revert PIP_MaxWalletExceeded();
        }

        super._transfer(sender, recipient, transferAmount);

        if (taxAmount > 0) {
            super._transfer(sender, taxWallet, taxAmount);
        }
    }

    receive() external payable {
        buyTokens();
    }

    function buyTokens() public payable {
        if (tokenPurchaseRate == 0) revert PIP_RateNotSet();
        if (msg.value == 0) revert("PIP: Send native currency to buy tokens");
        uint256 tokensToPurchase = (msg.value * tokenPurchaseRate);
        if (balanceOf(owner) < tokensToPurchase) revert PIP_InsufficientTokensForSale(balanceOf(owner), tokensToPurchase);
        _transfer(owner, _msgSender(), tokensToPurchase);
        emit TokensPurchased(_msgSender(), msg.value, tokensToPurchase);
    }

    function setTokenPurchaseRate(uint256 newRate) external onlyOwner { tokenPurchaseRate = newRate; }
    function setTradingEnabled(bool _enabled) external onlyOwner { tradingEnabled = _enabled; emit TradingEnabled(_enabled); }
    function setTaxesEnabled(bool _enabled) external onlyOwner { taxesEnabled = _enabled; emit TaxesEnabledSet(_enabled); }
    function setTaxRates(uint256 _buyTax, uint256 _sellTax) external onlyOwner {
        if (_buyTax > 25 || _sellTax > 25) revert PIP_TaxTooHigh(25);
        buyTaxPercent = _buyTax;
        sellTaxPercent = _sellTax;
        emit TaxRatesSet(_buyTax, _sellTax);
    }
    function setTaxWallet(address _taxWallet) external onlyOwner {
        if (_taxWallet == address(0)) revert PIP_ZeroAddress();
        taxWallet = _taxWallet;
        emit TaxWalletSet(_taxWallet);
    }
    function setDexPair(address _pair) external onlyOwner {
        if (_pair == address(0)) revert PIP_ZeroAddress();
        dexPair = _pair;
        emit DexPairSet(_pair);
    }
    function setLimits(uint256 _maxTx, uint256 _maxWallet) external onlyOwner {
        maxTxAmount = _maxTx;
        maxWalletAmount = _maxWallet;
        emit TxLimitsSet(_maxTx, _maxWallet);
    }
    function manageBlacklist(address _account, bool _isBlacklisted) external onlyOwner {
        if (_account == address(0)) revert PIP_ZeroAddress();
        isBlacklisted[_account] = _isBlacklisted;
        emit WalletBlacklistedStatusChanged(_account, _isBlacklisted);
    }
    function manageFeeExclusion(address _account, bool _isExcluded) external onlyOwner {
        if (_account == address(0)) revert PIP_ZeroAddress();
        if ((_account == owner || _account == address(this)) && !_isExcluded) {
            revert PIP_UnExcludeEssentialAddress();
        }
        isExcludedFromFees[_account] = _isExcluded;
        emit FeeExclusionStatusChanged(_account, _isExcluded);
    }
    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        if (recipients.length != amounts.length) revert PIP_MismatchedArrays();
        if (recipients.length == 0) revert PIP_EmptyRecipientsArray();
        uint256 totalAirdropAmount = 0;
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; ++i) {
            totalAirdropAmount += amounts[i];
        }
        if (balanceOf(owner) < totalAirdropAmount) revert PIP_InsufficientBalance();
        for (uint256 i = 0; i < len; ++i) {
            _transfer(owner, recipients[i], amounts[i]);
        }
        emit TokensAirdropped(owner, totalAirdropAmount);
    }
    function recoverStuckTokens(address _tokenAddress) external onlyOwner {
        if (_tokenAddress == address(this)) revert PIP_CannotWithdrawOwnToken();
        IERC20 token = IERC20(_tokenAddress);
        uint256 stuckBalance = token.balanceOf(address(this));
        if (stuckBalance == 0) revert PIP_NoStuckTokens();
        require(token.transfer(owner, stuckBalance), "PIP: Stuck token transfer failed");
        emit StuckTokensRecovered(_tokenAddress, stuckBalance);
    }
    function withdrawStuckNative() external onlyOwner {
        uint256 contractBalance = address(this).balance;
        if (contractBalance == 0) revert PIP_NoStuckTokens();
        (bool success, ) = payable(owner).call{value: contractBalance}("");
        if (!success) revert PIP_NativeTransferFailed();
        emit StuckNativeWithdrawn(contractBalance);
    }
}
