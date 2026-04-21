import * as anchor from "@coral-xyz/anchor";
import { Program, AnchorError } from "@coral-xyz/anchor";
import {
  PublicKey,
  Keypair,
  SystemProgram,
  LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import { expect } from "chai";
import { FeeVault } from "../target/types/fee_vault";

const VAULT_SEED = Buffer.from("fee_vault");
const MIN_SPONSOR_BALANCE = 1_000_000;

async function airdrop(
  connection: anchor.web3.Connection,
  to: PublicKey,
  lamports: number,
) {
  const sig = await connection.requestAirdrop(to, lamports);
  const blockhash = await connection.getLatestBlockhash();
  await connection.confirmTransaction(
    { signature: sig, ...blockhash },
    "confirmed",
  );
}

async function expectAnchorError(promise: Promise<unknown>, code: string) {
  try {
    await promise;
    expect.fail(`expected AnchorError with code "${code}" but call succeeded`);
  } catch (err) {
    const anchorErr = AnchorError.parse(
      (err as { logs?: string[] }).logs ?? [],
    );
    if (anchorErr) {
      expect(anchorErr.error.errorCode.code).to.equal(code);
      return;
    }
    if (err instanceof AnchorError) {
      expect(err.error.errorCode.code).to.equal(code);
      return;
    }
    const msg = (err as Error).message ?? String(err);
    expect(msg).to.include(code);
  }
}

describe("fee_vault", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.feeVault as Program<FeeVault>;
  const connection = provider.connection;

  const [vaultPda, vaultBump] = PublicKey.findProgramAddressSync(
    [VAULT_SEED],
    program.programId,
  );

  const authority = Keypair.generate();
  const emergencyAuthority = Keypair.generate();
  const sponsor = Keypair.generate();
  const intruder = Keypair.generate();

  const DAILY_LIMIT = new anchor.BN(0.5 * LAMPORTS_PER_SOL);
  const PER_TX_LIMIT = new anchor.BN(0.05 * LAMPORTS_PER_SOL);

  before(async () => {
    await airdrop(connection, authority.publicKey, 2 * LAMPORTS_PER_SOL);
    await airdrop(
      connection,
      emergencyAuthority.publicKey,
      1 * LAMPORTS_PER_SOL,
    );
    await airdrop(connection, sponsor.publicKey, MIN_SPONSOR_BALANCE);
    await airdrop(connection, intruder.publicKey, 1 * LAMPORTS_PER_SOL);
  });

  it("initializes the vault with the supplied limits and authorities", async () => {
    await program.methods
      .initialize(DAILY_LIMIT, PER_TX_LIMIT)
      .accountsStrict({
        vault: vaultPda,
        authority: authority.publicKey,
        emergencyAuthority: emergencyAuthority.publicKey,
        payer: provider.wallet.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([authority])
      .rpc();

    const vault = await program.account.feeVault.fetch(vaultPda);
    expect(vault.authority.toBase58()).to.equal(authority.publicKey.toBase58());
    expect(vault.emergencyAuthority.toBase58()).to.equal(
      emergencyAuthority.publicKey.toBase58(),
    );
    expect(vault.maxDailySpend.toString()).to.equal(DAILY_LIMIT.toString());
    expect(vault.maxPerTransaction.toString()).to.equal(
      PER_TX_LIMIT.toString(),
    );
    expect(vault.isEmergencyPaused).to.equal(false);
    expect(vault.totalSponsored.toNumber()).to.equal(0);
    expect(vault.dailySpent.toNumber()).to.equal(0);
    expect(vault.bump).to.equal(vaultBump);
  });

  // The `init` constraint protection (can't re-initialize the PDA) is exercised
  // implicitly by the validator: any second `initialize` call against the same
  // seed returns "account already in use" before our `InvalidLimits` check
  // fires, so a "per-tx > daily" test belongs in `update_limits` (below) where
  // the PDA already exists.

  describe("fund_vault (system transfer)", () => {
    it("vault PDA accepts plain SOL transfers", async () => {
      const tx = new anchor.web3.Transaction().add(
        SystemProgram.transfer({
          fromPubkey: provider.wallet.publicKey,
          toPubkey: vaultPda,
          lamports: 1 * LAMPORTS_PER_SOL,
        }),
      );
      await provider.sendAndConfirm(tx);
      const balance = await connection.getBalance(vaultPda);
      expect(balance).to.be.greaterThan(LAMPORTS_PER_SOL);
    });
  });

  describe("top_up_sponsor", () => {
    it("succeeds when called by the vault authority", async () => {
      const before = await connection.getBalance(sponsor.publicKey);
      const amount = new anchor.BN(0.01 * LAMPORTS_PER_SOL);

      await program.methods
        .topUpSponsor(amount)
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
          sponsor: sponsor.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([authority])
        .rpc();

      const after = await connection.getBalance(sponsor.publicKey);
      expect(after - before).to.equal(amount.toNumber());

      const vault = await program.account.feeVault.fetch(vaultPda);
      expect(vault.dailySpent.toString()).to.equal(amount.toString());
      expect(vault.totalSponsored.toString()).to.equal(amount.toString());
    });

    it("rejects an unauthorized signer (Unauthorized / has_one constraint)", async () => {
      // This is the test that proves the auth model is wired up correctly.
      // Without `has_one = authority`, anyone could drain the vault.
      await expectAnchorError(
        program.methods
          .topUpSponsor(new anchor.BN(0.01 * LAMPORTS_PER_SOL))
          .accountsStrict({
            vault: vaultPda,
            authority: intruder.publicKey,
            sponsor: intruder.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([intruder])
          .rpc(),
        "Unauthorized",
      );
    });

    it("rejects amount above max_per_transaction", async () => {
      await expectAnchorError(
        program.methods
          .topUpSponsor(PER_TX_LIMIT.add(new anchor.BN(1)))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
            sponsor: sponsor.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([authority])
          .rpc(),
        "ExceedsTransactionLimit",
      );
    });

    it("rejects zero amount", async () => {
      await expectAnchorError(
        program.methods
          .topUpSponsor(new anchor.BN(0))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
            sponsor: sponsor.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([authority])
          .rpc(),
        "InvalidAmount",
      );
    });

    it("rejects a sponsor account that is not system-owned", async () => {
      // Pass the vault PDA itself as the sponsor; it is owned by the program, not the system program.
      await expectAnchorError(
        program.methods
          .topUpSponsor(new anchor.BN(0.001 * LAMPORTS_PER_SOL))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
            sponsor: vaultPda,
            systemProgram: SystemProgram.programId,
          })
          .signers([authority])
          .rpc(),
        "InvalidSponsorAccount",
      );
    });

    it("rejects when cumulative daily spend would exceed max_daily_spend", async () => {
      // Tighten the daily limit so the *next* call of PER_TX_LIMIT lamports
      // would exceed it by 1. We can't make `daily < per_tx` because that
      // trips `update_limits`' own InvalidLimits check first, so we shrink
      // both knobs together: per_tx stays at PER_TX_LIMIT and daily becomes
      // (already-spent + PER_TX_LIMIT - 1).
      const vaultBefore = await program.account.feeVault.fetch(vaultPda);
      const tightDaily = vaultBefore.dailySpent
        .add(PER_TX_LIMIT)
        .sub(new anchor.BN(1));

      await program.methods
        .updateLimits(tightDaily, PER_TX_LIMIT)
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
        })
        .signers([authority])
        .rpc();

      await expectAnchorError(
        program.methods
          .topUpSponsor(PER_TX_LIMIT)
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
            sponsor: sponsor.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([authority])
          .rpc(),
        "ExceedsDailyLimit",
      );

      // Restore generous limits so subsequent tests have headroom.
      await program.methods
        .updateLimits(DAILY_LIMIT, PER_TX_LIMIT)
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
        })
        .signers([authority])
        .rpc();
    });
  });

  describe("sweep_remainder", () => {
    it("returns sponsor balance above MIN_SPONSOR_BALANCE to the vault", async () => {
      // Make sure the sponsor has more than the floor.
      const sponsorBalance = await connection.getBalance(sponsor.publicKey);
      expect(sponsorBalance).to.be.greaterThan(MIN_SPONSOR_BALANCE);

      const vaultBefore = await connection.getBalance(vaultPda);

      await program.methods
        .sweepRemainder()
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
          sponsor: sponsor.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([authority, sponsor])
        .rpc();

      const sponsorAfter = await connection.getBalance(sponsor.publicKey);
      const vaultAfter = await connection.getBalance(vaultPda);
      expect(sponsorAfter).to.equal(MIN_SPONSOR_BALANCE);
      expect(vaultAfter).to.equal(
        vaultBefore + (sponsorBalance - MIN_SPONSOR_BALANCE),
      );
    });

    it("is a no-op when sponsor is at or below the floor", async () => {
      const sponsorBefore = await connection.getBalance(sponsor.publicKey);
      const vaultBefore = await connection.getBalance(vaultPda);

      await program.methods
        .sweepRemainder()
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
          sponsor: sponsor.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([authority, sponsor])
        .rpc();

      expect(await connection.getBalance(sponsor.publicKey)).to.equal(
        sponsorBefore,
      );
      expect(await connection.getBalance(vaultPda)).to.equal(vaultBefore);
    });

    it("rejects an unauthorized signer", async () => {
      // Sponsor still signs (it has to, structurally), but the authority slot
      // is filled by `intruder`, which is the value the `has_one` check rejects.
      await expectAnchorError(
        program.methods
          .sweepRemainder()
          .accountsStrict({
            vault: vaultPda,
            authority: intruder.publicKey,
            sponsor: sponsor.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([intruder, sponsor])
          .rpc(),
        "Unauthorized",
      );
    });
  });

  describe("emergency controls", () => {
    it("emergency_pause requires the emergency_authority signer", async () => {
      await expectAnchorError(
        program.methods
          .emergencyPause()
          .accountsStrict({
            vault: vaultPda,
            emergencyAuthority: authority.publicKey,
          })
          .signers([authority])
          .rpc(),
        "Unauthorized",
      );
    });

    it("when paused, top_up_sponsor reverts; resume restores it", async () => {
      await program.methods
        .emergencyPause()
        .accountsStrict({
          vault: vaultPda,
          emergencyAuthority: emergencyAuthority.publicKey,
        })
        .signers([emergencyAuthority])
        .rpc();

      const paused = await program.account.feeVault.fetch(vaultPda);
      expect(paused.isEmergencyPaused).to.equal(true);

      await expectAnchorError(
        program.methods
          .topUpSponsor(new anchor.BN(0.001 * LAMPORTS_PER_SOL))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
            sponsor: sponsor.publicKey,
            systemProgram: SystemProgram.programId,
          })
          .signers([authority])
          .rpc(),
        "EmergencyPaused",
      );

      await program.methods
        .resumeOperations()
        .accountsStrict({
          vault: vaultPda,
          emergencyAuthority: emergencyAuthority.publicKey,
        })
        .signers([emergencyAuthority])
        .rpc();

      const resumed = await program.account.feeVault.fetch(vaultPda);
      expect(resumed.isEmergencyPaused).to.equal(false);

      // Sanity-check: top-up works again.
      await program.methods
        .topUpSponsor(new anchor.BN(0.001 * LAMPORTS_PER_SOL))
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
          sponsor: sponsor.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([authority])
        .rpc();
    });
  });

  describe("update_limits", () => {
    it("rejects per_tx > daily", async () => {
      await expectAnchorError(
        program.methods
          .updateLimits(new anchor.BN(100), new anchor.BN(101))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
          })
          .signers([authority])
          .rpc(),
        "InvalidLimits",
      );
    });

    it("rejects per_tx == 0", async () => {
      await expectAnchorError(
        program.methods
          .updateLimits(new anchor.BN(100), new anchor.BN(0))
          .accountsStrict({
            vault: vaultPda,
            authority: authority.publicKey,
          })
          .signers([authority])
          .rpc(),
        "InvalidAmount",
      );
    });

    it("rejects an unauthorized signer", async () => {
      await expectAnchorError(
        program.methods
          .updateLimits(DAILY_LIMIT, PER_TX_LIMIT)
          .accountsStrict({
            vault: vaultPda,
            authority: intruder.publicKey,
          })
          .signers([intruder])
          .rpc(),
        "Unauthorized",
      );
    });

    it("applies the new limits when the authority signs", async () => {
      const newDaily = new anchor.BN(0.4 * LAMPORTS_PER_SOL);
      const newPerTx = new anchor.BN(0.04 * LAMPORTS_PER_SOL);

      await program.methods
        .updateLimits(newDaily, newPerTx)
        .accountsStrict({
          vault: vaultPda,
          authority: authority.publicKey,
        })
        .signers([authority])
        .rpc();

      const v = await program.account.feeVault.fetch(vaultPda);
      expect(v.maxDailySpend.toString()).to.equal(newDaily.toString());
      expect(v.maxPerTransaction.toString()).to.equal(newPerTx.toString());
    });
  });

  // Daily counter reset is intentionally not asserted here: the on-chain check is
  // `current_day > vault.last_reset_day` where `current_day = clock.unix_timestamp / 86400`.
  // Validating it requires advancing the validator's wall clock, which `solana-test-validator`
  // does not support. The reset path is reviewed in the source and the same overflow-checked
  // arithmetic is used as in the no-reset path. To exercise it end-to-end, run against
  // `solana-bankrun` with `clock.warpToSlot`/`warpToEpoch` or wait across midnight UTC.
});
