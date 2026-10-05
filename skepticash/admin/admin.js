"use strict";

(() => {
  const db = window.SkeptiCashSupabase;
  const authView = document.querySelector("[data-auth-view]");
  const app = document.querySelector(".admin-app");
  const authForms = [...document.querySelectorAll("[data-admin-auth]")];
  const toast = document.querySelector(".toast");
  const model = { admin: null, page: "overview", users: [], wallets: [], transactions: [], deposits: [], withdrawals: [], plans: [], vipPayments: [], vipPaymentError: "", tasks: [], announcements: [], referrals: [], platformSettings: [], vipReferralRewards: [], vipReferralPayouts: [] };
  let vipPaymentRefreshTimer = 0;
  const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const formatMoney = (amount, decimals = 0) => `₦${Number(amount || 0).toLocaleString("en-NG", {
    minimumFractionDigits: decimals, maximumFractionDigits: decimals
  })}`;
  const escapeText = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);
  const dateText = (value) => value ? new Date(value).toLocaleDateString("en-NG", { day: "numeric", month: "short", year: "numeric" }) : "—";

  function notify(message, error = false) {
    const target = document.querySelector("[data-admin-error]");
    target.textContent = error ? message : "";
    toast.textContent = message;
    toast.classList.add("show");
    window.setTimeout(() => toast.classList.remove("show"), 3200);
  }

  function setAuthPage(name) {
    authView.hidden = false;
    app.hidden = true;
    authForms.forEach((form) => { form.hidden = form.dataset.adminAuth !== name; });
    document.querySelector(".config-message").hidden = true;
    window.location.hash = name === "login" ? "" : name;
    document.querySelector(`[data-admin-auth="${CSS.escape(name)}"] input`)?.focus();
  }

  function setPage(name) {
    model.page = name;
    document.querySelectorAll(".admin-page").forEach((page) => page.classList.toggle("active", page.dataset.page === name));
    document.querySelectorAll("[data-admin-page]").forEach((button) => button.classList.toggle("active", button.dataset.adminPage === name));
    document.querySelector("[data-page-title]").textContent = name === "vip" ? "VIP plans" : name === "settings" ? "General settings" :
      name.charAt(0).toUpperCase() + name.slice(1);
    if (name === "plans") {
      renderVipPayments();
      void refreshVipPayments();
    }
    document.querySelector(".admin-main").scrollTo({ top: 0, behavior: "smooth" });
  }

  function userById(id) {
    return model.users.find((user) => user.id === id);
  }

  function walletById(id) {
    return model.wallets.find((wallet) => wallet.user_id === id);
  }

  function taskMediaFile(formData) {
    const file = formData.get("media");
    if (!(file instanceof File) || !file.size) return null;
    const allowedTypes = new Set(["image/jpeg", "image/png", "image/webp", "image/gif", "video/mp4", "video/webm", "video/quicktime"]);
    if (!allowedTypes.has(file.type)) throw new Error("Choose a supported image or video file.");
    if (file.size > 20 * 1024 * 1024) throw new Error("Task media must be 20 MB or smaller.");
    return file;
  }

  function showTaskMediaPreview(form, file) {
    const preview = form.querySelector("[data-task-media-preview]");
    if (!preview) return;
    if (preview.dataset.objectUrl) URL.revokeObjectURL(preview.dataset.objectUrl);
    preview.replaceChildren();
    delete preview.dataset.objectUrl;
    if (!file) {
      preview.hidden = true;
      return;
    }
    const url = URL.createObjectURL(file);
    preview.dataset.objectUrl = url;
    const media = document.createElement(file.type.startsWith("video/") ? "video" : "img");
    media.src = url;
    media.alt = file.type.startsWith("image/") ? "Selected task image preview" : "";
    if (media instanceof HTMLVideoElement) {
      media.controls = true;
      media.muted = true;
      media.playsInline = true;
    }
    const label = document.createElement("p");
    label.className = "table-note";
    label.textContent = "Preview · not published yet";
    preview.append(label, media);
    preview.hidden = false;
  }

  async function uploadTaskMedia(file) {
    if (!file) return null;
    const extensions = {
      "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
      "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov"
    };
    const path = `${model.admin.id}/${crypto.randomUUID()}.${extensions[file.type]}`;
    await db.uploadFile("task-media", path, file);
    return path;
  }

  async function cleanupTaskMedia(path) {
    if (path) await db.deleteFiles("task-media", [path]);
  }

  function renderOverview() {
    const members = model.users.filter((user) => user.role === "user");
    document.querySelector('[data-stat="users"]').textContent = String(members.length);
    document.querySelector('[data-stat="balance"]').textContent =
      formatMoney(members.reduce((sum, user) => sum + Number(walletById(user.id)?.balance || 0), 0));
    document.querySelector('[data-stat="deposits"]').textContent =
      String(model.deposits.filter((item) => item.status === "pending").length);
    document.querySelector('[data-stat="withdrawals"]').textContent =
      String(model.withdrawals.filter((item) => item.status === "pending").length);
    document.querySelector('[data-stat="transactions"]').textContent = String(model.transactions.length);
    document.querySelector("[data-pending-count]").textContent =
      String(model.withdrawals.filter((item) => item.status === "pending").length);
    document.querySelector("[data-pending-deposits]").textContent =
      String(model.deposits.filter((item) => item.status === "pending").length);
    const rows = model.transactions.slice(0, 12).map((item) => {
      const user = userById(item.user_id);
      return `<tr><td><b>${escapeText(user?.full_name || "Member")}</b><br>${escapeText(user?.phone || user?.email || "—")}</td><td>${escapeText(item.type)}</td><td>${formatMoney(item.amount)}</td><td><span class="status ${escapeText(item.status)}">${escapeText(item.status)}</span></td><td>${dateText(item.created_at)}</td></tr>`;
    }).join("");
    document.querySelector("[data-recent-transactions]").innerHTML = rows || `<tr><td colspan="5">No transaction records yet.</td></tr>`;
  }

  function renderUsers(query = "") {
    const search = query.trim().toLowerCase();
    const rows = model.users.filter((user) => user.role === "user" &&
      `${user.full_name} ${user.phone} ${user.email} ${user.referral_code} ${userById(user.referred_by)?.phone} ${userById(user.referred_by)?.referral_code}`.toLowerCase().includes(search));
    document.querySelector("[data-users]").innerHTML = rows.map((user) => {
      const wallet = walletById(user.id);
      const referrer = userById(user.referred_by);
      const referredBy = referrer
        ? `${referrer.full_name || "Member"} · ${referrer.phone || "Phone unavailable"} · ${referrer.referral_code}`
        : "Direct / none";
      return `<tr><td><b>${escapeText(user.full_name || "Member")}</b></td><td>${escapeText(user.phone || user.email || "—")}</td><td>${escapeText(user.referral_code || "—")}</td><td>${escapeText(referredBy)}</td><td>VIP ${user.vip_level || 0}</td><td>${formatMoney(wallet?.balance, 2)}</td><td>${dateText(user.created_at)}</td><td><details class="member-manage"><summary class="small-button">Manage dashboard</summary><form class="row-actions" data-member-form="${escapeText(user.id)}"><label>Name<input aria-label="Member display name" class="small-input member-name-input" type="text" maxlength="160" name="fullName" value="${escapeText(user.full_name || "")}" required></label><label>Wallet balance<input aria-label="New balance in naira" class="small-input" type="number" min="0" step=".01" name="balance" value="${Number(wallet?.balance || 0).toFixed(2)}" required></label><label>VIP level<select aria-label="VIP level" class="small-select" name="vipLevel">${Array.from({ length: 10 }, (_, level) => `<option value="${level}" ${Number(user.vip_level) === level ? "selected" : ""}>VIP ${level}</option>`).join("")}</select></label><button class="small-button" type="submit">Save changes</button><button class="small-button danger" type="button" data-member-password-reset="${escapeText(user.id)}">Issue temporary password</button></form></details></td></tr>`;
    }).join("") || `<tr><td colspan="8">No members match your search.</td></tr>`;
    const memberCount = model.users.filter((user) => user.role === "user").length;
    document.querySelector("[data-user-count]").textContent = `Showing ${rows.length} of ${memberCount} loaded members.`;
  }

  function renderWithdrawals() {
    const rows = model.withdrawals.map((item) => {
      const user = userById(item.user_id);
      return `<tr><td><b>${escapeText(user?.full_name || "Member")}</b><br>${escapeText(user?.phone || user?.email || "—")}</td><td>${escapeText(item.account_name || "—")}</td><td>${escapeText(item.account_number || `••••${item.account_last4}`)}</td><td>${escapeText(item.bank_name || "—")}</td><td>${formatMoney(item.amount)}</td><td><span class="status ${escapeText(item.status)}">${escapeText(item.status)}</span></td><td>${dateText(item.created_at)}</td><td>${escapeText(item.admin_note || item.user_note || "—")}</td><td><input class="review-note" maxlength="500" placeholder="Optional note" aria-label="Withdrawal review note"><div class="row-actions"><button class="small-button" data-withdrawal-review="${escapeText(item.id)}" data-decision="approved">Approve</button><button class="small-button danger" data-withdrawal-review="${escapeText(item.id)}" data-decision="rejected">Reject</button></div></td></tr>`;
    }).join("");
    document.querySelector("[data-withdrawals]").innerHTML = rows || `<tr><td colspan="9">No withdrawal requests have been submitted.</td></tr>`;
  }

  function renderDeposits() {
    const rows = model.deposits.map((item) => {
      const user = userById(item.user_id);
      const paymentReported = Boolean(item.payment_submitted_at);
      const canRestore = item.status === "rejected";
      const note = paymentReported
        ? `Client reports payment · ${dateText(item.payment_submitted_at)}${item.admin_note ? ` · ${item.admin_note}` : ""}`
        : item.admin_note || "—";
      return `<tr><td><b>${escapeText(item.full_name || user?.full_name || "Member")}</b><br>${escapeText(item.phone || user?.phone || item.email || user?.email || "—")}</td><td>${formatMoney(item.amount)}</td><td><span class="status ${escapeText(item.status)}">${escapeText(item.status)}</span></td><td>${dateText(item.created_at)}</td><td>${dateText(item.expires_at)}</td><td>${escapeText(note)}</td><td><input class="review-note" maxlength="500" placeholder="Optional note" aria-label="Deposit review note"><div class="row-actions"><button class="small-button" data-deposit-review="${escapeText(item.id)}" data-decision="approved">Approve / credit</button><button class="small-button danger" data-deposit-review="${escapeText(item.id)}" data-decision="rejected">Reject / reverse</button>${canRestore ? `<button class="small-button" data-deposit-review="${escapeText(item.id)}" data-decision="restore">Restore request</button>` : ""}</div></td></tr>`;
    });
    document.querySelector("[data-deposits]").innerHTML = rows.join("") || `<tr><td colspan="7">No deposit requests have been submitted.</td></tr>`;
  }

  function renderTransactions() {
    document.querySelector("[data-transactions]").innerHTML = model.transactions.map((item) => {
      const user = userById(item.user_id);
      const deposit = model.deposits.find((request) => request.transaction_id === item.id);
      const withdrawal = model.withdrawals.find((request) => request.transaction_id === item.id);
      const actions = deposit
        ? `<div class="row-actions"><button class="small-button" data-deposit-review="${escapeText(deposit.id)}" data-decision="approved">Approve / restore</button><button class="small-button danger" data-deposit-review="${escapeText(deposit.id)}" data-decision="rejected">Reject</button></div>`
        : withdrawal
          ? `<div class="row-actions"><button class="small-button" data-withdrawal-review="${escapeText(withdrawal.id)}" data-decision="approved">Approve / restore</button><button class="small-button danger" data-withdrawal-review="${escapeText(withdrawal.id)}" data-decision="rejected">Reject</button></div>`
          : "—";
      return `<tr><td>${escapeText(user?.phone || user?.email || "—")}</td><td>${escapeText(item.type)}</td><td>${escapeText(item.description)}</td><td>${formatMoney(item.amount)}</td><td><span class="status ${escapeText(item.status)}">${escapeText(item.status)}</span></td><td>${dateText(item.created_at)}</td><td>${actions}</td></tr>`;
    }).join("") || `<tr><td colspan="7">No transaction records.</td></tr>`;
  }

  function renderReferrals() {
    document.querySelector("[data-referrals]").innerHTML = model.referrals.map((referral) => {
      const referrer = userById(referral.referrer_id);
      const member = userById(referral.referred_user_id);
      const payouts = model.vipReferralPayouts.filter((payout) => payout.referred_user_id === referral.referred_user_id);
      const rewardStatus = referral.level === 1
        ? payouts.map((payout) => `VIP ${payout.plan_level}: ${formatMoney(payout.amount)}`).join(", ") ||
          "Awaiting approved VIP purchase"
        : "—";
      const latestPayout = payouts.reduce((latest, payout) =>
        !latest || new Date(payout.paid_at) > new Date(latest.paid_at) ? payout : latest, null);
      return `<tr><td>${escapeText(referrer?.phone || referrer?.email || "—")}</td><td>${escapeText(member?.phone || member?.email || "—")}</td><td>Level ${referral.level}</td><td>${escapeText(referral.level === 1 ? rewardStatus : "—")}</td><td>${formatMoney(referral.earnings)}</td><td>${dateText(latestPayout?.paid_at || referral.created_at)}</td></tr>`;
    }).join("") || `<tr><td colspan="6">No referral records yet.</td></tr>`;
  }

  function renderPlans() {
    document.querySelector("[data-plans]").innerHTML = model.plans.map((plan) =>
      `<tr><td><b>VIP ${plan.level}</b></td><td><input class="small-input" type="number" min="0.01" step="0.01" name="upgrade_cost" value="${plan.upgrade_cost}" form="plan-${plan.level}" required></td><td><input class="small-input" type="number" min="1" step="1" name="daily_tasks" value="${plan.daily_tasks}" form="plan-${plan.level}" required></td><td><input class="small-input" type="number" min="0" step="1" name="task_commission" value="${plan.task_commission}" form="plan-${plan.level}" required></td><td><input class="small-input" type="number" name="daily_income" value="${plan.daily_income}" form="plan-${plan.level}" readonly></td><td><form id="plan-${plan.level}" data-plan-form="${plan.level}"><button class="small-button" type="submit">Save</button></form></td></tr>`
    ).join("") || `<tr><td colspan="6">VIP plan data is unavailable.</td></tr>`;
  }

  function renderVipPayments() {
    document.querySelector("[data-vip-payment-error]").textContent = model.vipPaymentError;
    document.querySelector("[data-vip-payments]").innerHTML = model.vipPayments.map((request) => {
      const user = userById(request.user_id);
      const canReview = request.status !== "approved";
      const statusLabel = request.status === "approved"
        ? `VIP ${Number(request.plan_level)} activated`
        : request.status === "rejected"
          ? "Payment rejected"
          : request.status === "expired"
            ? "Payment window expired"
            : request.payment_submitted_at
              ? `Client reports VIP ${Number(request.plan_level)} payment · awaiting approval`
              : `Awaiting VIP ${Number(request.plan_level)} payment`;
      return `<tr><td><b>${escapeText(request.full_name || user?.full_name || "Member")}</b><br>${escapeText(request.phone || user?.phone || request.email || user?.email || "—")}</td><td>VIP ${Number(request.plan_level)}</td><td>${formatMoney(request.amount, 2)}</td><td><span class="status ${escapeText(request.status)}">${escapeText(statusLabel)}</span></td><td>${dateText(request.payment_submitted_at || request.created_at)}</td><td>${dateText(request.expires_at)}</td><td>${escapeText(request.admin_note || "—")}</td><td>${canReview ? `<input class="review-note" maxlength="500" placeholder="Optional note" aria-label="VIP payment review note"><div class="row-actions"><button class="small-button" data-vip-review="${escapeText(request.id)}" data-decision="approved">Approve VIP ${Number(request.plan_level)}</button><button class="small-button danger" data-vip-review="${escapeText(request.id)}" data-decision="rejected">Reject</button></div>` : "Approved"}</td></tr>`;
    }).join("") || `<tr><td colspan="8">No VIP payment requests.</td></tr>`;
  }

  async function renderTasks() {
    for (const preview of document.querySelectorAll(".task-media-preview[data-object-url]")) {
      URL.revokeObjectURL(preview.dataset.objectUrl);
    }
    const taskCards = await Promise.all(model.tasks.map(async (task) => {
      let savedMediaMarkup = `<p class="table-note task-media-empty">No task image or video uploaded.</p>`;
      if (task.media_path) {
        try {
          const url = await db.createSignedUrl("task-media", task.media_path, 300);
          const isVideo = /\.(mp4|webm|mov)$/i.test(task.media_path);
          savedMediaMarkup = `<div class="task-saved-media"><p class="table-note">Uploaded task ${isVideo ? "video" : "image"} · visible to members</p>${isVideo
            ? `<video src="${escapeText(url)}" controls muted playsinline aria-label="Uploaded media for ${escapeText(task.title)}"></video>`
            : `<img src="${escapeText(url)}" alt="Uploaded task image: ${escapeText(task.title)}" loading="lazy">`}</div>`;
        } catch (error) {
          savedMediaMarkup = `<p class="table-note task-media-error">Uploaded task media preview unavailable: ${escapeText(error.message)}</p>`;
          console.error(`Task media preview failed for ${task.id}.`, error);
        }
      }
      return `<article class="task-admin-item"><form data-task-form="${escapeText(task.id)}"><label>Title<input name="title" value="${escapeText(task.title)}" required maxlength="100"></label><label>Description<input name="description" value="${escapeText(task.description)}" maxlength="500"></label><label>Reward (₦)<input name="reward_amount" type="number" min="0" step="1" value="${task.reward_amount}" required></label><label>Availability<select name="active"><option value="true" ${task.active ? "selected" : ""}>Active</option><option value="false" ${!task.active ? "selected" : ""}>Paused</option></select></label><p class="table-note task-reward-summary">Member reward: <b>${formatMoney(task.reward_amount)}</b> per completed task</p><div class="task-saved-media-wrap">${savedMediaMarkup}</div>${task.media_path ? `<label class="task-media-remove"><input name="remove_media" type="checkbox" value="yes"> Remove current media</label>` : ""}<label>Replace/add image or video<input name="media" type="file" accept="image/jpeg,image/png,image/webp,image/gif,video/mp4,video/webm,video/quicktime"></label><div class="task-media-preview" data-task-media-preview hidden></div><div class="row-actions"><button class="small-button" type="submit">Save task</button><button class="small-button danger" type="button" data-delete-task="${escapeText(task.id)}">Delete task</button></div></form></article>`;
    }));
    document.querySelector("[data-tasks]").innerHTML = taskCards.join("") || `<p class="table-note">No tasks yet. Use Create a task above to upload task media, set its reward and publish it.</p>`;
  }

  function renderWithdrawalDays() {
    const configured = model.platformSettings.find((setting) => setting.key === "withdrawal_days")?.value;
    const selectedDays = Array.isArray(configured) ? configured.map(Number) : [0, 1, 2, 3, 4, 5, 6];
    document.querySelector("[data-weekday-options]").innerHTML = weekdays.map((day, index) =>
      `<label><input type="checkbox" name="days" value="${index}" ${selectedDays.includes(index) ? "checked" : ""}>${day}</label>`
    ).join("");
  }

  function renderAnnouncements() {
    document.querySelector("[data-announcements]").innerHTML = model.announcements.map((announcement) =>
      `<article class="announcement-item"><form data-announcement-form="${escapeText(announcement.id)}"><label>Title<input name="title" value="${escapeText(announcement.title)}" required maxlength="120"></label><label>Message<textarea name="body" rows="3" required maxlength="2000">${escapeText(announcement.body)}</textarea></label><label>Visibility<select name="active"><option value="true" ${announcement.active ? "selected" : ""}>Published</option><option value="false" ${!announcement.active ? "selected" : ""}>Archived</option></select></label><div class="row-actions"><button class="small-button" type="submit">Save</button><button class="small-button danger" type="button" data-delete-announcement="${escapeText(announcement.id)}">Delete</button></div></form></article>`
    ).join("") || `<p class="table-note">No announcements have been published.</p>`;
  }

  function renderAccountDefaults() {
    const settings = Object.fromEntries(model.platformSettings.map((setting) => [setting.key, setting.value]));
    const form = document.querySelector("[data-account-defaults]");
    form.elements.startingBalance.value = Number(settings.default_starting_balance || 0).toFixed(2);
    form.elements.vipLevel.value = String(Number(settings.default_vip_level || 0));
  }

  function renderVipReferralRewards() {
    document.querySelector("[data-vip-referral-reward-fields]").innerHTML = model.plans.map((plan) => {
      const reward = model.vipReferralRewards.find((item) => Number(item.level) === Number(plan.level));
      return `<label>VIP ${Number(plan.level)} reward (₦)<input name="level-${Number(plan.level)}" type="number" min="0" max="999999999999.99" step="0.01" value="${Number(reward?.reward_amount || 0).toFixed(2)}" required></label>`;
    }).join("");
  }

  function renderManualDepositSettings() {
    const settings = model.platformSettings.find((setting) => setting.key === "manual_deposit_details")?.value || {};
    const form = document.querySelector("[data-manual-deposit-settings]");
    form.elements.accountName.value = settings.account_name || "";
    form.elements.accountNumber.value = settings.account_number || "";
    form.elements.bankName.value = settings.bank_name || "";
    form.elements.instruction.value = settings.instruction || "";
  }

  async function renderAll() {
    renderOverview();
    renderUsers(document.querySelector("[data-user-search]").value);
    renderWithdrawals();
    renderDeposits();
    renderTransactions();
    renderReferrals();
    renderPlans();
    renderVipPayments();
    await renderTasks();
    renderAnnouncements();
    renderAccountDefaults();
    renderVipReferralRewards();
    renderManualDepositSettings();
    renderWithdrawalDays();
  }

  async function refreshData() {
    try {
      await db.rpc("admin_expire_manual_deposits");
    } catch (error) {
      console.error("Manual deposit auto-expiry could not run.", error);
      notify(`Deposit auto-expiry unavailable: ${error.message}.`, true);
    }
    try {
      await db.rpc("admin_expire_vip_payments");
    } catch (error) {
      console.error("VIP payment auto-expiry could not run.", error);
      notify(`VIP payment auto-expiry unavailable: ${error.message}. Apply migration 009 and reload the schema cache.`, true);
    }
    const vipPaymentsPromise = refreshVipPayments();
    const [users, wallets, transactions, deposits, withdrawals, plans, tasks, announcements, referrals, platformSettings, vipReferralRewards, vipReferralPayouts] = await Promise.all([
      db.select("profiles", { columns: "id,email,phone,full_name,role,vip_level,referral_code,referred_by,created_at", order: "created_at.desc", limit: 1000 }),
      db.select("wallets", { columns: "user_id,balance", limit: 1000 }),
      db.select("transactions", { columns: "id,user_id,type,amount,status,description,created_at", order: "created_at.desc", limit: 1000 }),
      db.select("deposits", { columns: "id,user_id,full_name,email,phone,amount,status,admin_note,transaction_id,created_at,expires_at,payment_submitted_at", order: "created_at.desc", limit: 500 }),
      db.select("withdrawals", { columns: "id,user_id,amount,bank_name,account_last4,account_name,account_number,status,user_note,admin_note,transaction_id,created_at", order: "created_at.desc", limit: 500 }),
      db.select("vip_plans", { columns: "level,upgrade_cost,daily_tasks,task_commission,daily_income", order: "level.asc" }),
      db.select("tasks", { columns: "id,title,description,reward_amount,active,media_path,created_at,deleted_at", filters: { deleted_at: { is: "null" } }, order: "created_at.desc", limit: 500 }),
      db.select("announcements", { columns: "id,title,body,active,created_at", order: "created_at.desc", limit: 200 }),
      db.select("referrals", { columns: "id,referrer_id,referred_user_id,level,commission_percent,earnings,reward_amount,reward_paid_at,created_at", order: "created_at.desc", limit: 1000 }),
      db.select("platform_settings", { columns: "key,value" }),
      db.select("vip_referral_reward_rates", { columns: "level,reward_amount", order: "level.asc" }),
      db.select("vip_referral_rewards", { columns: "referrer_id,referred_user_id,plan_level,amount,paid_at", order: "paid_at.desc", limit: 1000 })
    ]);
    Object.assign(model, { users, wallets, transactions, deposits, withdrawals, plans, tasks, announcements, referrals, platformSettings, vipReferralRewards, vipReferralPayouts });
    await vipPaymentsPromise;
    await renderAll();
  }

  async function refreshVipPayments(render = true) {
    try {
      model.vipPayments = await db.select("vip_payment_requests", {
        columns: "id,user_id,plan_level,full_name,email,phone,amount,status,payment_submitted_at,admin_note,created_at,expires_at",
        order: "created_at.desc",
        limit: 500
      });
      model.vipPaymentError = "";
    } catch (error) {
      model.vipPayments = [];
      model.vipPaymentError = `VIP payment requests could not be loaded: ${error.message}. Apply migrations 007 and 009, then refresh.`;
      console.error("VIP payment requests could not be loaded.", error);
    }
    if (render) renderVipPayments();
  }

  async function openAdmin(user) {
    const profile = await db.select("profiles", { columns: "id,role,email,phone", filters: { id: user.id } });
    if (!profile[0] || profile[0].role !== "admin") {
      await db.signOut();
      throw new Error("Administrator access is required for this deployment.");
    }
    model.admin = profile[0];
    document.querySelector("[data-admin-email]").textContent = profile[0].email || user.email || "Administrator";
    authView.hidden = true;
    app.hidden = false;
    setPage("overview");
    window.clearInterval(vipPaymentRefreshTimer);
    vipPaymentRefreshTimer = window.setInterval(() => {
      if (document.visibilityState !== "visible" || !model.admin) return;
      const requestTable = document.querySelector("[data-vip-payments]");
      const isEditingReview = requestTable.contains(document.activeElement) ||
        [...requestTable.querySelectorAll(".review-note")].some((input) => input.value.trim());
      void refreshVipPayments(!isEditingReview && model.page === "plans");
    }, 15000);
    try {
      await refreshData();
    } catch (error) {
      notify(`Admin data refresh failed: ${error.message}`, true);
      await refreshVipPayments();
    }
  }

  async function submitAuth(form) {
    const feedback = form.querySelector(".feedback");
    const submit = form.querySelector('[type="submit"]');
    const data = new FormData(form);
    const originalButtonContent = submit.innerHTML;
    const loadingLabels = { login: "Signing in..." };
    feedback.textContent = "";
    submit.disabled = true;
    submit.classList.add("is-loading");
    submit.setAttribute("aria-busy", "true");
    submit.textContent = loadingLabels[form.dataset.adminAuth] || "Please wait...";
    try {
      if (form.dataset.adminAuth === "login") {
        const result = await db.signIn({ email: data.get("email").trim(), password: data.get("password") });
        await openAdmin(result.user);
      }
    } catch (error) {
      feedback.textContent = error.message;
    } finally {
      submit.disabled = false;
      submit.classList.remove("is-loading");
      submit.removeAttribute("aria-busy");
      submit.innerHTML = originalButtonContent;
    }
  }

  async function handleSubmit(event) {
    const form = event.target;
    if (form.matches("[data-admin-auth]")) {
      event.preventDefault();
      await submitAuth(form);
      return;
    }
    if (form.matches("[data-member-form]")) {
      event.preventDefault();
      const data = new FormData(form);
      const userId = form.dataset.memberForm;
      try {
        await db.rpc("admin_manage_member", {
          p_user_id: userId,
          p_full_name: data.get("fullName").trim(),
          p_balance: Number(data.get("balance")),
          p_vip_level: Number(data.get("vipLevel"))
        });
        await refreshData();
        notify("Member dashboard updated.");
      } catch (error) { notify(`Member update failed: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-account-defaults]")) {
      event.preventDefault();
      const data = new FormData(form);
      try {
        const result = await db.rpc("admin_update_account_defaults", {
          p_starting_balance: Number(data.get("startingBalance")),
          p_vip_level: Number(data.get("vipLevel"))
        });
        await refreshData();
        notify(`Defaults saved. Updated ${Number(result.wallets_updated || 0)} untouched wallets and ${Number(result.profiles_updated || 0)} VIP levels.`);
      } catch (error) { notify(`Account defaults could not be saved: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-vip-referral-rewards]")) {
      event.preventDefault();
      const data = new FormData(form);
      try {
        await db.rpc("admin_save_vip_referral_rewards", {
          p_rewards: model.plans.map((plan) => ({
            level: Number(plan.level),
            amount: Number(data.get(`level-${plan.level}`))
          }))
        });
        await refreshData();
        notify("VIP referral rewards saved.");
      } catch (error) { notify(`VIP referral rewards could not be saved: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-manual-deposit-settings]")) {
      event.preventDefault();
      const data = new FormData(form);
      try {
        await db.rpc("admin_save_manual_deposit_details", {
          p_account_name: data.get("accountName").trim(),
          p_account_number: data.get("accountNumber").trim(),
          p_bank_name: data.get("bankName").trim(),
          p_instruction: data.get("instruction").trim()
        });
        await refreshData();
        notify("Manual deposit details saved.");
      } catch (error) { notify(`Payment details could not be saved: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-withdrawal-days]")) {
      event.preventDefault();
      const days = [...form.querySelectorAll('input[name="days"]:checked')].map((input) => Number(input.value));
      if (!days.length) { notify("Select at least one withdrawal day.", true); return; }
      try {
        await db.rpc("admin_save_withdrawal_days", { p_days: days });
        await refreshData();
        notify("Withdrawal days saved.");
      } catch (error) { notify(`Withdrawal days could not be saved: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-plan-form]")) {
      event.preventDefault();
      const data = new FormData(form);
      const plan = Object.fromEntries(data.entries());
      try {
        await db.update("vip_plans", { level: form.dataset.planForm }, {
          upgrade_cost: Number(plan.upgrade_cost),
          daily_tasks: Number(plan.daily_tasks),
          task_commission: Number(plan.task_commission),
          daily_income: Number(plan.daily_tasks) * Number(plan.task_commission),
          updated_at: new Date().toISOString()
        });
        await refreshData();
        notify("VIP plan updated.");
      } catch (error) { notify(`Plan update failed: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-task-create]")) {
      event.preventDefault();
      const data = new FormData(form);
      let mediaPath = null;
      let taskCreated = false;
      try {
        mediaPath = await uploadTaskMedia(taskMediaFile(data));
        await db.insert("tasks", {
          ...(mediaPath ? { media_path: mediaPath } : {}),
          title: data.get("title").trim(),
          description: data.get("description").trim(),
          reward_amount: Number(data.get("reward")),
          active: true
        });
        taskCreated = true;
        form.reset();
        showTaskMediaPreview(form, null);
        await refreshData();
        notify("Task created.");
      } catch (error) {
        if (mediaPath && !taskCreated) {
          try { await cleanupTaskMedia(mediaPath); }
          catch (cleanupError) { console.error("Uploaded task media cleanup failed.", cleanupError); }
        }
        notify(taskCreated
          ? `Task was created, but the task list could not be refreshed: ${error.message}`
          : `Task creation failed: ${error.message}`, true);
      }
      return;
    }
    if (form.matches("[data-task-form]")) {
      event.preventDefault();
      const data = new FormData(form);
      const task = model.tasks.find((item) => item.id === form.dataset.taskForm);
      const previousMediaPath = task?.media_path || null;
      let replacementPath = null;
      let mediaPath = previousMediaPath;
      try {
        replacementPath = await uploadTaskMedia(taskMediaFile(data));
        if (replacementPath) mediaPath = replacementPath;
        else if (data.get("remove_media") === "yes") mediaPath = null;
        await db.update("tasks", { id: form.dataset.taskForm }, {
          title: data.get("title").trim(),
          description: data.get("description").trim(),
          reward_amount: Number(data.get("reward_amount")),
          active: data.get("active") === "true",
          media_path: mediaPath,
          updated_at: new Date().toISOString()
        });
      } catch (error) {
        if (replacementPath) {
          try { await cleanupTaskMedia(replacementPath); }
          catch (cleanupError) { console.error("Uploaded task media cleanup failed.", cleanupError); }
        }
        notify(`Task update failed: ${error.message}`, true);
        return;
      }
      let cleanupErrorMessage = "";
      if (previousMediaPath && previousMediaPath !== mediaPath) {
        try { await cleanupTaskMedia(previousMediaPath); }
        catch (error) { cleanupErrorMessage = error.message; }
      }
      try {
        await refreshData();
        notify(cleanupErrorMessage
          ? `Task updated, but old media could not be removed: ${cleanupErrorMessage}`
          : "Task updated.", Boolean(cleanupErrorMessage));
      } catch (error) { notify(`Task updated but refresh failed: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-announcement-create]")) {
      event.preventDefault();
      const data = new FormData(form);
      try {
        await db.insert("announcements", {
          title: data.get("title").trim(),
          body: data.get("body").trim(),
          active: true,
          created_by: model.admin.id
        });
        form.reset();
        await refreshData();
        notify("Announcement published.");
      } catch (error) { notify(`Announcement failed: ${error.message}`, true); }
      return;
    }
    if (form.matches("[data-announcement-form]")) {
      event.preventDefault();
      const data = new FormData(form);
      try {
        await db.update("announcements", { id: form.dataset.announcementForm }, {
          title: data.get("title").trim(),
          body: data.get("body").trim(),
          active: data.get("active") === "true",
          updated_at: new Date().toISOString()
        });
        await refreshData();
        notify("Announcement updated.");
      } catch (error) { notify(`Announcement update failed: ${error.message}`, true); }
    }
  }

  async function initialize() {
    document.addEventListener("submit", handleSubmit);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible" && model.admin) {
        void refreshVipPayments(model.page === "plans");
      }
    });
    document.addEventListener("click", async (event) => {
      const passwordReset = event.target.closest("[data-member-password-reset]");
      if (passwordReset) {
        const confirmed = window.confirm(
          "Issue a new temporary password for this member? Their existing password cannot be viewed. The temporary password will be shown once."
        );
        if (!confirmed) return;
        passwordReset.disabled = true;
        try {
          const session = await db.getSession();
          if (!session?.access_token) throw new Error("Administrator session expired. Sign in again.");
          const response = await fetch("/api/member-auth", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${session.access_token}`
            },
            body: JSON.stringify({
              action: "admin-reset-password",
              userId: passwordReset.dataset.memberPasswordReset
            }),
            cache: "no-store"
          });
          const result = await response.json();
          if (!response.ok) throw new Error(result.error || `Password reset failed (${response.status}).`);
          window.alert(
            `Temporary password for ${result.phone}:\n\n${result.temporaryPassword}\n\nCopy it now and give it securely to the member. It will not be shown again. Ask the member to change it after signing in.`
          );
          notify("Temporary password issued. The previous password remains unrecoverable.");
        } catch (error) {
          notify(`Password reset failed: ${error.message}`, true);
        } finally {
          passwordReset.disabled = false;
        }
        return;
      }
      const nav = event.target.closest("[data-admin-page]");
      if (nav) {
        setPage(nav.dataset.adminPage);
        if (nav.dataset.adminPage === "users") {
          try { await refreshData(); }
          catch (error) { notify(`Member list refresh failed: ${error.message}`, true); }
        }
        return;
      }
      if (event.target.closest("[data-refresh]")) {
        try { await refreshData(); notify("Admin data refreshed."); }
        catch (error) { notify(`Refresh failed: ${error.message}`, true); }
        return;
      }
      const review = event.target.closest("[data-withdrawal-review]");
      if (review) {
        review.disabled = true;
        try {
          await db.rpc("admin_review_withdrawal", {
            p_withdrawal_id: review.dataset.withdrawalReview,
            p_decision: review.dataset.decision,
            p_admin_note: review.closest("td").querySelector(".review-note")?.value.trim() || ""
          });
          await refreshData();
          notify(`Withdrawal ${review.dataset.decision}.`);
        } catch (error) {
          review.disabled = false;
          notify(`Withdrawal review failed: ${error.message}`, true);
        }
        return;
      }
      const vipReview = event.target.closest("[data-vip-review]");
      if (vipReview) {
        vipReview.disabled = true;
        try {
          const request = await db.rpc("admin_review_vip_payment", {
            p_request_id: vipReview.dataset.vipReview,
            p_decision: vipReview.dataset.decision,
            p_admin_note: vipReview.closest("td").querySelector(".review-note")?.value.trim() || ""
          });
          await refreshData();
          notify(request.status === "approved"
            ? `VIP ${request.plan_level} payment approved. The member's VIP level is now active.`
            : "VIP payment rejected. The member wallet was not changed.");
        } catch (error) {
          vipReview.disabled = false;
          notify(`VIP payment review failed: ${error.message}`, true);
        }
        return;
      }
      const depositReview = event.target.closest("[data-deposit-review]");
      if (depositReview) {
        depositReview.disabled = true;
        try {
          const reviewedDeposit = await db.rpc("admin_review_deposit", {
            p_deposit_id: depositReview.dataset.depositReview,
            p_decision: depositReview.dataset.decision,
            p_admin_note: depositReview.closest("td").querySelector(".review-note")?.value.trim() || ""
          });
          await refreshData();
          notify(reviewedDeposit.status === "expired"
            ? "Deposit request expired before it could be reviewed."
            : reviewedDeposit.status === "completed" ? "Deposit approved and wallet credited."
              : reviewedDeposit.status === "pending" ? "Rejected request restored to pending review."
                : reviewedDeposit.status === "rejected" ? "Deposit rejected." : "Deposit review updated.");
        } catch (error) {
          depositReview.disabled = false;
          notify(`Deposit review failed: ${error.message}`, true);
        }
        return;
      }
      const receiptButton = event.target.closest("[data-admin-receipt]");
      if (receiptButton) {
        const receiptWindow = window.open("about:blank", "_blank");
        if (!receiptWindow) { notify("Allow pop-ups to open the private receipt.", true); return; }
        receiptWindow.opener = null;
        receiptButton.disabled = true;
        try {
          receiptWindow.location.href = await db.createSignedUrl("deposit-proofs", receiptButton.dataset.adminReceipt);
        } catch (error) {
          receiptWindow.close();
          notify(`Receipt unavailable: ${error.message}`, true);
        } finally { receiptButton.disabled = false; }
        return;
      }
      const deleteTask = event.target.closest("[data-delete-task]");
      if (deleteTask) {
        if (!window.confirm("Delete this task and remove it from the member task list? Existing completion and transaction history will be preserved.")) return;
        let taskDeleted = false;
        try {
          const task = model.tasks.find((item) => item.id === deleteTask.dataset.deleteTask);
          await db.update("tasks", { id: deleteTask.dataset.deleteTask }, {
            active: false,
            deleted_at: new Date().toISOString(),
            media_path: null,
            updated_at: new Date().toISOString()
          });
          taskDeleted = true;
          if (task?.media_path) {
            try { await cleanupTaskMedia(task.media_path); }
            catch (error) {
              await refreshData();
              notify(`Task removed from member lists, but its stored media could not be deleted: ${error.message}`, true);
              return;
            }
          }
          await refreshData();
          notify("Task deleted.");
        } catch (error) {
          notify(taskDeleted
            ? `Task was removed from member lists, but the admin list could not be refreshed: ${error.message}`
            : `Task deletion failed: ${error.message}`, true);
        }
        return;
      }
      const deleteAnnouncement = event.target.closest("[data-delete-announcement]");
      if (deleteAnnouncement) {
        if (!window.confirm("Delete this announcement?")) return;
        try {
          await db.remove("announcements", { id: deleteAnnouncement.dataset.deleteAnnouncement });
          await refreshData();
          notify("Announcement deleted.");
        } catch (error) { notify(`Announcement deletion failed: ${error.message}`, true); }
        return;
      }
      if (event.target.closest('[data-action="logout"]')) {
        try {
          await db.signOut();
          model.admin = null;
          window.clearInterval(vipPaymentRefreshTimer);
          vipPaymentRefreshTimer = 0;
          setAuthPage("login");
        }
        catch (error) { notify(`Sign out failed: ${error.message}`, true); }
      }
    });
    document.querySelector("[data-user-search]").addEventListener("input", (event) => renderUsers(event.target.value));
    document.addEventListener("input", (event) => {
      const form = event.target.form;
      if (!form?.matches("[data-plan-form]") || !["daily_tasks", "task_commission"].includes(event.target.name)) return;
      const income = document.querySelector(`input[form="${CSS.escape(form.id)}"][name="daily_income"]`);
      const tasks = Number(document.querySelector(`input[form="${CSS.escape(form.id)}"][name="daily_tasks"]`).value);
      const commission = Number(document.querySelector(`input[form="${CSS.escape(form.id)}"][name="task_commission"]`).value);
      income.value = String(tasks * commission);
    });
    document.addEventListener("change", (event) => {
      const input = event.target;
      if (!(input instanceof HTMLInputElement) || input.name !== "media") return;
      const form = input.form;
      if (!form?.matches("[data-task-create], [data-task-form]")) return;
      try {
        showTaskMediaPreview(form, taskMediaFile(new FormData(form)));
      } catch (error) {
        showTaskMediaPreview(form, null);
        notify(error.message, true);
      }
    });
    if (!db.isConfigured()) {
      authForms.forEach((form) => { form.hidden = form.dataset.adminAuth !== "login"; });
      document.querySelector(".config-message").hidden = false;
      return;
    }
    try {
      const session = await db.getSession();
      if (session?.user?.id) await openAdmin(session.user);
      else setAuthPage("login");
    } catch (error) {
      setAuthPage("login");
      notify(`Admin setup failed: ${error.message}`, true);
    }
  }

  initialize();
})();
