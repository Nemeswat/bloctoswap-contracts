import FungibleToken from 0xFUNGIBLETOKENADDRESS

pub contract TeleportedTetherToken: FungibleToken {

  // Total supply of TeleportedTetherTokens in existence
  pub var totalSupply: UFix64

  // Event that is emitted when the contract is created
  pub event TokensInitialized(initialSupply: UFix64)

  // Event that is emitted when tokens are withdrawn from a Vault
  pub event TokensWithdrawn(amount: UFix64, from: Address?)

  // Event that is emitted when tokens are deposited to a Vault
  pub event TokensDeposited(amount: UFix64, to: Address?)

  // Event that is emitted when new tokens are minted
  pub event TokensMinted(amount: UFix64)

  // Event that is emitted when tokens are destroyed
  pub event TokensBurned(amount: UFix64)

  // Event that is emitted when new tokens are teleported in from Ethereum (from: Ethereum Address, 21 bytes)
  pub event TokensTeleportedIn(amount: UFix64, from: [UInt8; 21])

  // Event that is emitted when tokens are destroyed and teleported to Ethereum (to: Ethereum Address, 21 bytes)
  pub event TokensTeleportedOut(amount: UFix64, to: [UInt8; 21])

  // Event that is emitted when a new burner resource is created
  pub event TeleportAdminCreated()

  // Vault
  //
  // Each user stores an instance of only the Vault in their storage
  // The functions in the Vault and governed by the pre and post conditions
  // in FungibleToken when they are called.
  // The checks happen at runtime whenever a function is called.
  //
  // Resources can only be created in the context of the contract that they
  // are defined in, so there is no way for a malicious user to create Vaults
  // out of thin air. A special Minter resource needs to be defined to mint
  // new tokens.
  //
  pub resource Vault: FungibleToken.Provider, FungibleToken.Receiver, FungibleToken.Balance {
    
    // holds the balance of a users tokens
    pub var balance: UFix64

    // initialize the balance at resource creation time
    init(balance: UFix64) {
      self.balance = balance
    }

    // withdraw
    //
    // Function that takes an integer amount as an argument
    // and withdraws that amount from the Vault.
    // It creates a new temporary Vault that is used to hold
    // the money that is being transferred. It returns the newly
    // created Vault to the context that called so it can be deposited
    // elsewhere.
    //
    pub fun withdraw(amount: UFix64): @FungibleToken.Vault {
      self.balance = self.balance - amount
      emit TokensWithdrawn(amount: amount, from: self.owner?.address)
      return <-create Vault(balance: amount)
    }

    // deposit
    //
    // Function that takes a Vault object as an argument and adds
    // its balance to the balance of the owners Vault.
    // It is allowed to destroy the sent Vault because the Vault
    // was a temporary holder of the tokens. The Vault's balance has
    // been consumed and therefore can be destroyed.
    pub fun deposit(from: @FungibleToken.Vault) {
      let vault <- from as! @TeleportedTetherToken.Vault
      self.balance = self.balance + vault.balance
      emit TokensDeposited(amount: vault.balance, to: self.owner?.address)
      vault.balance = 0.0
      destroy vault
    }

    destroy() {
      TeleportedTetherToken.totalSupply = TeleportedTetherToken.totalSupply - self.balance
    }
  }

  // createEmptyVault
  //
  // Function that creates a new Vault with a balance of zero
  // and returns it to the calling context. A user must call this function
  // and store the returned Vault in their storage in order to allow their
  // account to be able to receive deposits of this token type.
  //
  pub fun createEmptyVault(): @FungibleToken.Vault {
    return <-create Vault(balance: 0.0)
  }

  pub resource Administrator {

    // createNewTeleportAdmin
    //
    // Function that creates and returns a new teleport admin resource
    //
    pub fun createNewTeleportAdmin(feeCollector: @FungibleToken.Vault{FungibleToken.Receiver}): @TeleportAdmin {
      emit TeleportAdminCreated()
      return <-create TeleportAdmin(feeCollector: feeCollector, inwardFee: 0.01, outwardFee: 1.0)
    }
  }

  // TeleportAdmin resource
  //
  //  Resource object that has the capability to mint teleported tokens
  //  upon receiving teleport request from Ethereum side
  //
  pub resource TeleportAdmin {
    // receiver to collect teleport fee
    pub var feeCollector: @TeleportedTetherToken.Vault{FungibleToken.Receiver}

    // fee collected when token is teleported from Ethereum to Flow
    pub var inwardFee: UFix64

    // fee collected when token is teleported from Flow to Ethereum
    pub var outwardFee: UFix64

    // teleportIn
    //
    // Function that mints new tokens, adds them to the total supply,
    // and returns them to the calling context.
    //
    pub fun teleportIn(amount: UFix64, from: [UInt8; 21]): @TeleportedTetherToken.Vault {
      pre {
        amount > inwardFee: "Amount minted must be greater than inward teleport fee"
      }
      TeleportedTetherToken.totalSupply = TeleportedTetherToken.totalSupply + Amount
      emit TokensTeleportedIn(amount: amount, from: from)

      let vault <-create Vault(balance: amount)
      let fee <- from vault.withdraw(inwardFee)
      feeCollector.deposit(fee)

      return vault
    }

    // teleportOut
    //
    // Function that destroys a Vault instance, effectively burning the tokens.
    //
    // Note: the burned tokens are automatically subtracted from the 
    // total supply in the Vault destructor.
    //
    pub fun teleportOut(from: @FungibleToken.Vault, to: [UInt8; 21]) {
      let vault <- from as! @TeleportedTetherToken.Vault
      let fee <- from vault.withdraw(outwardFee)
      feeCollector.deposit(fee)

      let amount = vault.balance
      destroy vault
      emit TokensTeleportedOut(amount: amount, to: to)
    }

    pub fun updateFeeCollector(feeCollector: @FungibleToken.Vault{FungibleToken.Receiver}) {
      self.feeCollector = feeCollector
    }

    pub fun updateInwardFee(fee: UFix64) {
      self.inwardFee = fee
    }

    pub fun updateOutwardFee(fee: UFix64) {
      self.outwardFee = fee
    }

    init(feeCollector: @FungibleToken.Vault{FungibleToken.Receiver}, inwardFee: UFix64, outwardFee: UFix64) {
      self.feeCollector = feeCollector
      self.inwardFee = inwardFee
      self.outwardFee = outwardFee
    }
  }

  init(adminAccount: AuthAccount) {
    self.totalSupply = 0.0

    // Create the Vault with the total supply of tokens and save it in storage
    //
    let vault <- create Vault(balance: self.totalSupply)
    adminAccount.save(<-vault, to: /storage/teleportedTetherTokenVault)

    // Create a public capability to the stored Vault that only exposes
    // the `deposit` method through the `Receiver` interface
    //
    adminAccount.link<&TeleportedTetherToken.Vault{FungibleToken.Receiver}>(
      /public/teleportedTetherTokenReceiver,
      target: /storage/teleportedTetherTokenVault
    )

    // Create a public capability to the stored Vault that only exposes
    // the `balance` field through the `Balance` interface
    //
    adminAccount.link<&TeleportedTetherToken.Vault{FungibleToken.Balance}>(
      /public/teleportedTetherTokenBalance,
      target: /storage/teleportedTetherTokenVault
    )

    let admin <- create Administrator()
    adminAccount.save(<-admin, to: /storage/teleportedTetherTokenAdmin)

    // Emit an event that shows that the contract was initialized
    emit TokensInitialized(initialSupply: self.totalSupply)
  }
}
