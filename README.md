# Token Vesting Vault

> **What it is about:** A secure corporate treasury vault for streaming ERC-20 token allocations to employees, investors, or grant recipients over time.
>
> **What it does:** Locks tokens under a custom schedule and releases them linearly only after a cliff period has elapsed, allows beneficiaries to claim their unlocked tokens on-demand without double-claim risk, and supports fair revocation where unvested tokens return to the company while all tokens vested to date remain claimable by the recipient.

---

## Key Features & Architecture

- **Linear Stream Math with Cliff:**
  - Strictly 0 tokens vested or releasable before `start + cliff`.
  - Continuous linear vesting between `start + cliff` and `start + duration`.
  - 100% vested at or beyond `start + duration`.
- **Beneficiary Claims & Custody:**
  - Only authorized beneficiaries can trigger claims on their schedules.
  - Double-claim and overclaiming protection.
  - Safe token custody with OpenZeppelin `SafeERC20`.
- **Fair Revocation Mechanics:**
  - If a revocable schedule is revoked by the owner, unvested tokens are immediately refunded to the owner.
  - Tokens vested up to the revocation timestamp are locked in and remain permanently claimable by the beneficiary.
  - Prevents repeat revocation or revoking non-revocable schedules.

## Project Structure

```
├── foundry.toml
├── src/
│   └── TokenVestingVault.sol
├── script/
│   └── TokenVestingVault.s.sol
└── test/
    ├── TokenVestingVault.t.sol
    └── mocks/
        └── MockERC20.sol
```

## Getting Started

### Prerequisites
- [Foundry](https://getfoundry.sh/)

### Build
```bash
forge build
```

### Run Tests
```bash
forge test -vvv
```

All 11 test vectors pass, verifying pre-cliff jumps (`vm.warp`), cliff releases, progressive claims, fair revocation, unauthorized attempts, and fuzz testing schedule linearity.
