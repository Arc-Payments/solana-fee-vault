//! # fee_vault
//!
//! A PDA-backed fee sponsor for gasless SPL token transfers on Solana.
//!
//! ## Overview
//!
//! `fee_vault` holds SOL in a single program-derived address (the "vault PDA"). When a
//! sponsored transaction is built, three on-chain steps happen atomically inside the same
//! transaction:
//!
//! 1. `top_up_sponsor` moves at most `max_lamports` from the vault PDA to a system-owned
//!    `sponsor` account. The sponsor account is the transaction fee payer.
//! 2. The user's payload (e.g. an SPL token transfer authorized by the user's wallet) runs.
//! 3. (Optional) `sweep_remainder` moves any unused lamports from the sponsor back to the
//!    vault, leaving a small floor in the sponsor for rent exemption.
//!
//! Because all three steps are in one transaction, the vault is never out of pocket for more
//! than the per-transaction limit, even if step 2 fails.
//!
//! ## Authority model
//!
//! - `authority` (a normal Ed25519 keypair) signs `top_up_sponsor`, `sweep_remainder`, and
//!   `update_limits`. This is the operational hot key the sponsor service uses.
//! - `emergency_authority` signs `emergency_pause` and `resume_operations`. This is a
//!   separate cold key intended for incident response: it can halt all top-ups instantly
//!   without needing to touch or rotate the operational `authority`.
//!
//! ## Limits
//!
//! `max_per_transaction` and `max_daily_spend` are configurable per vault and enforced
//! on-chain. They bound the blast radius if the operational `authority` is compromised.

#![allow(unexpected_cfgs)]
#![allow(deprecated)]

use anchor_lang::prelude::*;
use anchor_lang::solana_program::system_program;

declare_id!("4fjNH5DfvXbfNv45DevfweY2D5sLzgdWCQ1MK6zY9HR8");

/// Lamports kept in the sponsor after a sweep so the account stays rent-exempt.
const MIN_SPONSOR_BALANCE: u64 = 1_000_000;

/// Number of seconds in a day, used for the `daily_spent` reset rollover.
const SECONDS_PER_DAY: i64 = 86_400;

#[program]
pub mod fee_vault {
    use super::*;

    /// Initialize the fee vault PDA.
    ///
    /// The PDA is derived from the seed `b"fee_vault"`. There is exactly one vault per
    /// program deployment.
    ///
    /// `max_daily_spend` and `max_per_transaction` are denominated in lamports.
    /// `max_per_transaction <= max_daily_spend` is enforced.
    pub fn initialize(
        ctx: Context<Initialize>,
        max_daily_spend: u64,
        max_per_transaction: u64,
    ) -> Result<()> {
        require!(max_per_transaction > 0, ErrorCode::InvalidAmount);
        require!(
            max_per_transaction <= max_daily_spend,
            ErrorCode::InvalidLimits
        );

        let vault = &mut ctx.accounts.vault;
        vault.authority = ctx.accounts.authority.key();
        vault.emergency_authority = ctx.accounts.emergency_authority.key();
        vault.is_emergency_paused = false;
        vault.total_sponsored = 0;
        vault.daily_spent = 0;
        vault.last_reset_day = Clock::get()?.unix_timestamp / SECONDS_PER_DAY;
        vault.max_daily_spend = max_daily_spend;
        vault.max_per_transaction = max_per_transaction;
        vault.bump = ctx.bumps.vault;

        msg!(
            "fee_vault initialized: daily={} per_tx={} authority={} emergency={}",
            max_daily_spend,
            max_per_transaction,
            vault.authority,
            vault.emergency_authority
        );
        Ok(())
    }

    /// Move up to `max_lamports` from the vault PDA to the `sponsor` account.
    ///
    /// Requires the vault `authority` to sign. The `sponsor` account must be system-owned
    /// (i.e. a regular wallet, not another program's PDA), because it will be the fee payer
    /// of the surrounding transaction.
    ///
    /// Per-transaction and per-day limits are enforced. The daily counter rolls over the
    /// first time this instruction is called on a new UTC day.
    pub fn top_up_sponsor(ctx: Context<TopUpSponsor>, max_lamports: u64) -> Result<()> {
        require!(max_lamports > 0, ErrorCode::InvalidAmount);

        let current_day = Clock::get()?.unix_timestamp / SECONDS_PER_DAY;
        let vault = &ctx.accounts.vault;

        require!(!vault.is_emergency_paused, ErrorCode::EmergencyPaused);
        require!(
            max_lamports <= vault.max_per_transaction,
            ErrorCode::ExceedsTransactionLimit
        );

        let projected_daily = if current_day > vault.last_reset_day {
            max_lamports
        } else {
            vault
                .daily_spent
                .checked_add(max_lamports)
                .ok_or(ErrorCode::ArithmeticOverflow)?
        };
        require!(
            projected_daily <= vault.max_daily_spend,
            ErrorCode::ExceedsDailyLimit
        );

        require!(
            ctx.accounts.sponsor.owner == &system_program::ID,
            ErrorCode::InvalidSponsorAccount
        );

        let vault_info = ctx.accounts.vault.to_account_info();
        let sponsor_info = ctx.accounts.sponsor.to_account_info();

        require!(
            vault_info.lamports() >= max_lamports,
            ErrorCode::InsufficientFunds
        );

        // Direct lamport mutation is the canonical Anchor pattern when the source account
        // is program-owned (the vault PDA) and the destination is system-owned. A
        // `system_program::transfer` CPI would fail because the system program rejects
        // transfers from accounts it does not own.
        **vault_info.try_borrow_mut_lamports()? = vault_info
            .lamports()
            .checked_sub(max_lamports)
            .ok_or(ErrorCode::ArithmeticOverflow)?;
        **sponsor_info.try_borrow_mut_lamports()? = sponsor_info
            .lamports()
            .checked_add(max_lamports)
            .ok_or(ErrorCode::ArithmeticOverflow)?;

        let vault = &mut ctx.accounts.vault;
        if current_day > vault.last_reset_day {
            vault.daily_spent = max_lamports;
            vault.last_reset_day = current_day;
        } else {
            vault.daily_spent = vault
                .daily_spent
                .checked_add(max_lamports)
                .ok_or(ErrorCode::ArithmeticOverflow)?;
        }
        vault.total_sponsored = vault
            .total_sponsored
            .checked_add(max_lamports)
            .ok_or(ErrorCode::ArithmeticOverflow)?;

        msg!(
            "top_up_sponsor: amount={} daily_spent={}/{}",
            max_lamports,
            vault.daily_spent,
            vault.max_daily_spend
        );
        Ok(())
    }

    /// Sweep any sponsor balance above `MIN_SPONSOR_BALANCE` back into the vault PDA.
    ///
    /// Requires the vault `authority` to sign. Idempotent: if the sponsor balance is at or
    /// below the floor, nothing is moved. The floor exists so the sponsor account stays
    /// rent-exempt across sponsored transactions.
    ///
    /// `total_sponsored` is **not** decremented here: it tracks gross outflow over the
    /// vault's lifetime, not net spend.
    pub fn sweep_remainder(ctx: Context<SweepRemainder>) -> Result<()> {
        require!(
            !ctx.accounts.vault.is_emergency_paused,
            ErrorCode::EmergencyPaused
        );
        require!(
            ctx.accounts.sponsor.owner == &system_program::ID,
            ErrorCode::InvalidSponsorAccount
        );

        let sponsor_info = ctx.accounts.sponsor.to_account_info();
        let vault_info = ctx.accounts.vault.to_account_info();

        let sponsor_balance = sponsor_info.lamports();
        if sponsor_balance <= MIN_SPONSOR_BALANCE {
            msg!("sweep_remainder: nothing to sweep (balance={})", sponsor_balance);
            return Ok(());
        }

        let sweep_amount = sponsor_balance - MIN_SPONSOR_BALANCE;
        **sponsor_info.try_borrow_mut_lamports()? = MIN_SPONSOR_BALANCE;
        **vault_info.try_borrow_mut_lamports()? = vault_info
            .lamports()
            .checked_add(sweep_amount)
            .ok_or(ErrorCode::ArithmeticOverflow)?;

        msg!("sweep_remainder: amount={}", sweep_amount);
        Ok(())
    }

    /// Pause all top-ups. Only the `emergency_authority` can call this.
    pub fn emergency_pause(ctx: Context<EmergencyControl>) -> Result<()> {
        ctx.accounts.vault.is_emergency_paused = true;
        msg!(
            "emergency_pause activated by {}",
            ctx.accounts.emergency_authority.key()
        );
        Ok(())
    }

    /// Resume top-ups after an emergency pause. Only the `emergency_authority` can call this.
    pub fn resume_operations(ctx: Context<EmergencyControl>) -> Result<()> {
        ctx.accounts.vault.is_emergency_paused = false;
        msg!(
            "operations resumed by {}",
            ctx.accounts.emergency_authority.key()
        );
        Ok(())
    }

    /// Update the per-day and per-transaction limits.
    ///
    /// Requires the vault `authority` to sign. Enforces
    /// `0 < new_max_per_transaction <= new_max_daily_spend`.
    pub fn update_limits(
        ctx: Context<UpdateLimits>,
        new_max_daily_spend: u64,
        new_max_per_transaction: u64,
    ) -> Result<()> {
        require!(new_max_per_transaction > 0, ErrorCode::InvalidAmount);
        require!(
            new_max_per_transaction <= new_max_daily_spend,
            ErrorCode::InvalidLimits
        );

        let vault = &mut ctx.accounts.vault;
        vault.max_daily_spend = new_max_daily_spend;
        vault.max_per_transaction = new_max_per_transaction;

        msg!(
            "update_limits: daily={} per_tx={}",
            new_max_daily_spend,
            new_max_per_transaction
        );
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + FeeVault::INIT_SPACE,
        seeds = [b"fee_vault"],
        bump
    )]
    pub vault: Account<'info, FeeVault>,

    /// The hot operational key. Will sign `top_up_sponsor`, `sweep_remainder`, and
    /// `update_limits`. Recorded on the vault for `has_one` checks.
    pub authority: Signer<'info>,

    /// CHECK: stored on the vault for `has_one` checks. Marked `SystemAccount` so the
    /// runtime verifies it is system-owned.
    pub emergency_authority: SystemAccount<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct TopUpSponsor<'info> {
    #[account(
        mut,
        seeds = [b"fee_vault"],
        bump = vault.bump,
        has_one = authority @ ErrorCode::Unauthorized,
    )]
    pub vault: Account<'info, FeeVault>,

    /// Must be the `authority` recorded on the vault.
    pub authority: Signer<'info>,

    /// The fee payer of the surrounding transaction. Must be system-owned.
    /// CHECK: ownership is asserted in the instruction handler.
    #[account(mut)]
    pub sponsor: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SweepRemainder<'info> {
    #[account(
        mut,
        seeds = [b"fee_vault"],
        bump = vault.bump,
        has_one = authority @ ErrorCode::Unauthorized,
    )]
    pub vault: Account<'info, FeeVault>,

    pub authority: Signer<'info>,

    /// CHECK: ownership is asserted in the instruction handler.
    #[account(mut)]
    pub sponsor: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct EmergencyControl<'info> {
    #[account(
        mut,
        seeds = [b"fee_vault"],
        bump = vault.bump,
        has_one = emergency_authority @ ErrorCode::Unauthorized,
    )]
    pub vault: Account<'info, FeeVault>,

    pub emergency_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateLimits<'info> {
    #[account(
        mut,
        seeds = [b"fee_vault"],
        bump = vault.bump,
        has_one = authority @ ErrorCode::Unauthorized,
    )]
    pub vault: Account<'info, FeeVault>,

    pub authority: Signer<'info>,
}

#[account]
#[derive(InitSpace)]
pub struct FeeVault {
    /// Hot key authorized to top up, sweep, and update limits.
    pub authority: Pubkey,
    /// Cold key authorized to pause and resume.
    pub emergency_authority: Pubkey,
    /// When `true`, every top-up reverts.
    pub is_emergency_paused: bool,
    /// Lifetime gross outflow from the vault, in lamports.
    pub total_sponsored: u64,
    /// Outflow on the current UTC day, in lamports.
    pub daily_spent: u64,
    /// `unix_timestamp / SECONDS_PER_DAY` at the last counter reset.
    pub last_reset_day: i64,
    /// Maximum cumulative outflow per UTC day, in lamports.
    pub max_daily_spend: u64,
    /// Maximum outflow per single `top_up_sponsor` call, in lamports.
    pub max_per_transaction: u64,
    /// PDA bump seed.
    pub bump: u8,
}

#[error_code]
pub enum ErrorCode {
    #[msg("Caller is not authorized for this instruction")]
    Unauthorized,
    #[msg("Vault is emergency paused")]
    EmergencyPaused,
    #[msg("Amount exceeds per-transaction limit")]
    ExceedsTransactionLimit,
    #[msg("Amount would exceed daily spending limit")]
    ExceedsDailyLimit,
    #[msg("Amount must be greater than zero")]
    InvalidAmount,
    #[msg("Sponsor account must be system-owned")]
    InvalidSponsorAccount,
    #[msg("max_per_transaction must be <= max_daily_spend")]
    InvalidLimits,
    #[msg("Vault has insufficient lamports for this top-up")]
    InsufficientFunds,
    #[msg("Arithmetic overflow")]
    ArithmeticOverflow,
}
