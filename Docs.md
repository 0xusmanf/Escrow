## System Architecture
### High-Level Flow
```
Buyer → Creates Escrow → Deposits Funds
              ↓
    Seller Delivers
              ↓
    Buyer Confirms/Disputes
              ↓
    Release or Arbitrate
```

### Contract Architecture
```
EscrowFactory.sol (Main Entry Point)
    ├── Creates new escrow instances
    ├── Tracks all escrows
    └── Manages arbiter registry

Escrow.sol (Individual Escrow Instance)
    ├── Holds funds
    ├── Manages state transitions
    └── Handles releases/disputes

ArbiterRegistry.sol
    ├── Registers verified arbiters
    ├── Tracks arbiter reputation
    └── Manages arbiter stakes
```