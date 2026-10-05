"use strict";

(() => {
  const db = window.SkeptiCashSupabase;
  const proofBucket = "deposit-proofs";
  const maxProofSize = 5 * 1024 * 1024;
  const allowedProofTypes = new Set(["image/jpeg", "image/png", "image/webp", "application/pdf"]);

  async function submitDeposit({ userId, amount, proof, note = "" }) {
    if (!proof || !allowedProofTypes.has(proof.type) || proof.size === 0 || proof.size > maxProofSize) {
      throw new Error("Choose a JPG, PNG, WebP, or PDF receipt no larger than 5 MB.");
    }
    const depositId = crypto.randomUUID();
    const path = `${userId}/${depositId}/${proof.name.replace(/[^\w.-]/g, "_").slice(0, 100) || "receipt"}`;
    await db.uploadFile(proofBucket, path, proof);
    try {
      return await db.rpc("submit_deposit", {
        p_amount: Number(amount),
        p_proof_path: path,
        p_user_note: note.trim()
      });
    } catch (error) {
      try { await db.deleteFiles(proofBucket, [path]); }
      catch (cleanupError) {
        console.error("Could not remove an unlinked deposit receipt:", cleanupError.message);
      }
      throw error;
    }
  }

  async function requestWithdrawal({ amount, bankName, accountName, accountNumber }) {
    return db.rpc("request_withdrawal", {
      p_amount: Number(amount),
      p_account_name: accountName.trim(),
      p_account_number: accountNumber.trim(),
      p_bank_name: bankName.trim()
    });
  }

  async function allowedWithdrawalDays() {
    const result = await db.rpc("get_withdrawal_days");
    if (!Array.isArray(result) || result.length === 0 ||
        result.some((day) => !Number.isInteger(Number(day)) || Number(day) < 0 || Number(day) > 6)) {
      throw new Error("Supabase returned an invalid withdrawal schedule.");
    }
    return [...new Set(result.map(Number))];
  }

  async function beginTaskMedia(taskId) {
    const result = await db.rpc("begin_task_media", { p_task_id: taskId });
    if (typeof result?.attempt_id !== "string" || typeof result?.started_at !== "string") {
      throw new Error("Supabase returned an invalid task attempt.");
    }
    return result;
  }

  async function finishTaskMedia(attemptId, touched) {
    const result = await db.rpc("finish_task_media", {
      p_attempt_id: attemptId,
      p_touched: Boolean(touched)
    });
    if (!["completed", "missed"].includes(result?.status)) {
      throw new Error("Supabase returned an invalid task result.");
    }
    return result;
  }

  async function createVipPayment({ planLevel, fullName, phone }) {
    return db.rpc("create_vip_payment_request", {
      p_plan_level: Number(planLevel),
      p_full_name: fullName.trim(),
      p_phone: phone.trim()
    });
  }

  async function confirmVipPayment(requestId) {
    return db.rpc("confirm_vip_payment", { p_request_id: requestId });
  }

  async function expireVipPayment(requestId) {
    return db.rpc("expire_vip_payment", { p_request_id: requestId });
  }

  async function getManualDepositDetails() {
    const result = await db.rpc("get_manual_deposit_details");
    if (!result || typeof result.account_name !== "string" ||
        typeof result.account_number !== "string" || typeof result.bank_name !== "string") {
      throw new Error("Supabase returned invalid manual deposit details.");
    }
    return result;
  }

  async function createManualDeposit({ fullName, phone, amount }) {
    return db.rpc("create_manual_deposit", {
      p_full_name: fullName.trim(),
      p_phone: phone.trim(),
      p_amount: Number(amount)
    });
  }

  async function expireManualDeposit(depositId) {
    return db.rpc("expire_manual_deposit", { p_deposit_id: depositId });
  }

  async function confirmManualDepositPayment(depositId) {
    return db.rpc("confirm_manual_deposit_payment", { p_deposit_id: depositId });
  }

  async function walletSummary() {
    const result = await db.rpc("get_wallet_summary");
    const keys = ["available_balance", "total_earnings", "referral_earnings", "task_earnings", "pending_deposits", "pending_withdrawals"];
    for (const key of keys) {
      if (!Number.isFinite(Number(result?.[key]))) throw new Error(`Wallet summary is missing a valid ${key} amount.`);
    }
    return Object.fromEntries(keys.map((key) => [key, Number(result[key])]));
  }

  const transactionService = Object.freeze({
    list: (userId, { page = 0, pageSize = 50, filters = {} } = {}) => db.select("transactions", {
      columns: "id,type,amount,status,description,created_at",
      filters: { user_id: userId, ...filters },
      order: "created_at.desc",
      limit: pageSize + 1,
      range: [page * pageSize, (page + 1) * pageSize]
    }),
    listDeposits: async (userId, limit = 100) => {
      await db.rpc("expire_user_manual_deposits");
      return db.select("deposits", {
        columns: "id,amount,status,user_note,admin_note,proof_path,transaction_id,created_at,reviewed_at,expires_at",
        filters: { user_id: userId },
        order: "created_at.desc",
        limit
      });
    },
    listWithdrawals: (userId, limit = 100) => db.select("withdrawals", {
      columns: "id,amount,status,bank_name,account_name,account_last4,admin_note,transaction_id,created_at,reviewed_at",
      filters: { user_id: userId },
      order: "created_at.desc",
      limit
    })
  });

  window.SkeptiCashFinance = Object.freeze({
    wallet: Object.freeze({ summary: walletSummary }),
    deposits: Object.freeze({ submit: submitDeposit, getManualDetails: getManualDepositDetails, createManual: createManualDeposit, expire: expireManualDeposit, confirmPayment: confirmManualDepositPayment }),
    withdrawals: Object.freeze({ request: requestWithdrawal, allowedDays: allowedWithdrawalDays }),
    taskMedia: Object.freeze({ begin: beginTaskMedia, finish: finishTaskMedia }),
    vip: Object.freeze({ create: createVipPayment, confirm: confirmVipPayment, expire: expireVipPayment }),
    transactions: transactionService,
    storage: Object.freeze({ createReceiptUrl: (path) => db.createSignedUrl(proofBucket, path) })
  });
})();
