"use strict";

(() => {
  const db = window.SkeptiCashSupabase;
  const finance = window.SkeptiCashFinance;
  const plans = [];
  const app = document.querySelector(".app");
  const publicHome = document.querySelector('[data-public="home"]');
  const authScreens = [...document.querySelectorAll("[data-auth-screen]")];
  const toast = document.querySelector(".toast");
  const modal = document.querySelector(".modal-backdrop");
  const moreSheet = document.querySelector(".more-backdrop");
  const paymentForm = document.querySelector(".payment-form");
  const paymentAmount = document.querySelector("#payment-amount");
  const state = {
    page: "home",
    user: null,
    walletBalance: null,
    transactions: [],
    deposits: [],
    withdrawals: [],
    historyPage: 0,
    historyHasNext: false,
    tasks: [],
    completedTaskIds: new Set(),
    referralLink: "",
    toastTimer: 0,
    hiddenBalance: false,
    activeTaskLimit: 0,
    depositStage: "form",
    depositCountdown: 0,
    activeDepositId: null,
    taskMediaTimer: 0,
    taskMediaCountdown: 0,
    activeTaskMediaAttempt: null,
    taskMediaAttempts: new Map(),
    withdrawalDays: null,
    vipPlanLevel: null,
    activeVipRequestId: null
  };

  const money = (amount, decimals = 0) => `₦${Number(amount || 0).toLocaleString("en-NG", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals
  })}`;
  const escapeText = (value) => String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character]);
  const currentPath = `${window.location.origin}${window.location.pathname}`;

  function showToast(message) {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("show");
    window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => toast.classList.remove("show"), 3200);
  }

  function showPublicPage(name) {
    app.hidden = true;
    publicHome.hidden = name !== "home";
    authScreens.forEach((screen) => { screen.hidden = screen.dataset.authScreen !== name; });
    if (name === "home") window.scrollTo({ top: 0, behavior: "smooth" });
    else document.querySelector(`[data-auth-screen="${CSS.escape(name)}"]`)?.querySelector("input")?.focus();
    window.history.replaceState(null, "", name === "home" ? currentPath : `${currentPath}#${name}`);
  }

  function setPage(page, refresh = true) {
    const selectedScreen = document.querySelector(`[data-screen="${CSS.escape(page)}"]`);
    if (!selectedScreen) return;
    state.page = page;
    document.querySelectorAll(".screen").forEach((screen) => screen.classList.toggle("active", screen === selectedScreen));
    document.querySelectorAll(".bottom-nav-item").forEach((button) => {
      const selected = button.dataset.page === page ||
        (button.dataset.action === "more" && ["vip", "history", "profile"].includes(page));
      button.classList.toggle("selected", selected);
      if (selected && button.hasAttribute("data-page")) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    });
    closeMore();
    window.scrollTo({ top: 0, behavior: "smooth" });
    document.querySelector("#main-content").focus({ preventScroll: true });
    if (refresh) {
      if (page === "wallet" || page === "history") loadTransactions(page === "history" ? state.historyPage : 0);
      if (page === "wallet" || page === "home") loadWallet();
      if (page === "tasks" || page === "home") loadProfile().then(loadTasks);
      else if (["profile", "vip"].includes(page)) loadProfile();
      if (page === "team") loadReferralData();
    }
    if (page !== "tasks") clearTaskMedia();
  }

  function setBalanceVisibility() {
    document.querySelectorAll(".balance-amount").forEach((element) => {
      element.textContent = state.hiddenBalance
        ? "••••••"
        : element.dataset.value ? money(element.dataset.value, 2) : "—";
    });
    document.querySelectorAll(".balance-visibility").forEach((button) => {
      button.setAttribute("aria-label", state.hiddenBalance ? "Show balance" : "Hide balance");
      button.setAttribute("aria-pressed", String(state.hiddenBalance));
      button.innerHTML = state.hiddenBalance
        ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18M10.6 10.6a2 2 0 0 0 2.8 2.8"/><path d="M9.9 5.2A10.6 10.6 0 0 1 12 5c6.4 0 10 7 10 7a14 14 0 0 1-3.1 3.8M6.2 6.2C3.5 8 2 12 2 12s3.6 7 10 7a10 10 0 0 0 4.2-.9"/></svg>'
        : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>';
    });
  }

  async function loadProfile() {
    try {
      const result = await db.select("profiles", {
        columns: "id,email,phone,full_name,vip_level,referral_code",
        filters: { id: state.user.id },
        single: true
      });
      if (!result) throw new Error("Member profile is not available yet. Refresh in a moment.");
      state.user = result;
      const fullName = result.full_name || result.phone || "Member";
      const firstName = fullName.trim().split(/\s+/)[0] || "Member";
      const initials = fullName.trim().split(/\s+/).slice(0, 2).map((part) => part[0].toUpperCase()).join("");
      document.querySelector(".account-name").textContent = firstName;
      document.querySelector('[data-screen="home"] [data-greeting]').firstChild.textContent = `Welcome back, ${firstName} `;
      document.querySelectorAll("[data-user-initials], [data-profile-initials]").forEach((item) => { item.textContent = initials; });
      document.querySelector("[data-home-vip]").textContent = result.vip_level ? String(result.vip_level) : "—";
      document.querySelector(".profile-card h2").textContent = fullName;
      document.querySelector(".profile-card p").textContent = result.phone || "Phone number unavailable";
      document.querySelector(".profile-card .member-pill").lastChild.textContent =
        result.vip_level ? ` VIP ${result.vip_level} member` : " SkeptiCash member";
      const plansResult = await db.select("vip_plans", { columns: "level,upgrade_cost,daily_tasks,task_commission,daily_income", order: "level.asc" });
      plans.splice(0, plans.length, ...plansResult);
      renderPlans();
      const activePlan = plans.find((plan) => plan.level === result.vip_level);
      document.querySelector("[data-membership-label]").innerHTML = activePlan
        ? `VIP ${activePlan.level} <span>Active</span>`
        : "No active VIP plan";
      document.querySelector("[data-membership-summary]").textContent = activePlan
        ? `${activePlan.daily_tasks} daily ${activePlan.daily_tasks === 1 ? "task" : "tasks"} · ${money(activePlan.task_commission)} per completed task`
        : "View available VIP plans";
      state.activeTaskLimit = Number(activePlan?.daily_tasks || 0);
    } catch (error) {
      showToast(`Account details unavailable: ${error.message}`);
    }
  }

  async function loadWallet() {
    try {
      const result = await finance.wallet.summary();
      state.walletBalance = result.available_balance;
      document.querySelectorAll(".balance-amount").forEach((element) => {
        element.dataset.value = String(result.available_balance);
      });
      Object.entries(result).forEach(([key, amount]) => {
        const value = document.querySelector(`[data-wallet-summary="${key}"]`);
        if (value) value.textContent = money(amount);
      });
      document.querySelectorAll("[data-balance-error]").forEach((element) => { element.textContent = ""; });
      setBalanceVisibility();
    } catch (error) {
      state.walletBalance = null;
      document.querySelectorAll(".balance-amount").forEach((element) => { element.dataset.value = ""; });
      document.querySelectorAll("[data-wallet-summary]").forEach((element) => { element.textContent = "—"; });
      document.querySelectorAll("[data-balance-error]").forEach((element) => { element.textContent = error.message; });
      setBalanceVisibility();
    }
  }

  function transactionMarkup(transaction) {
    const type = String(transaction.type || "task").toLowerCase();
    const outgoing = type === "withdrawal";
    const purchase = type === "vip_purchase";
    const status = String(transaction.status || "pending").toLowerCase();
    const succeeded = ["completed", "approved"].includes(status);
    const statusClass = succeeded ? "success" : ["failed", "rejected", "expired"].includes(status) ? "failed" : "pending";
    const date = transaction.created_at
      ? new Date(transaction.created_at).toLocaleDateString("en-NG", { day: "numeric", month: "short" })
      : "—";
    const icon = type === "deposit" ? "↓" : outgoing ? "↑" : purchase ? "Ⅱ" : "✓";
    const description = String(transaction.description || `${type} transaction`)
      .replace(/manual bank transfer|manual deposit/gi, "deposit");
    const prefix = purchase ? "" : outgoing ? "−" : succeeded ? "+" : "*";
    const amountClass = succeeded && !outgoing && !purchase ? "incoming" : purchase ? "purchase" : "";
    return `<article class="activity-row" data-kind="${escapeText(type)}"><span class="activity-icon ${escapeText(type)}">${icon}</span><span class="activity-copy"><b>${escapeText(description)}</b><small>${escapeText(date)} <i class="activity-status ${statusClass}">${escapeText(status)}</i></small></span><span class="activity-amount ${amountClass}">${prefix}${money(transaction.amount, purchase ? 2 : 0)}</span></article>`;
  }

  function renderActivity() {
    const selectedFilter = document.querySelector(".screen.active .record-tabs .record-tab.selected")?.dataset.recordFilter || "all";
    const matching = selectedFilter === "all" ? state.transactions :
      state.transactions.filter((record) => record.type === selectedFilter);
    const records = matching.length ? matching.map(transactionMarkup).join("") :
      `<div class="empty-state"><strong>No transactions yet</strong><span>Your wallet activity will appear here.</span></div>`;
    const recent = state.transactions.slice(0, 3).map(transactionMarkup).join("") ||
      `<div class="empty-state"><strong>No recent activity</strong><span>Your wallet updates will show here.</span></div>`;
    const preview = document.querySelector("[data-activity-preview]");
    if (preview) preview.innerHTML = recent;
    document.querySelectorAll("[data-record-list], [data-history-full]").forEach((list) => { list.innerHTML = records; });
    document.querySelectorAll("[data-history-list]").forEach((list) => {
      const kind = list.dataset.historyList;
      const requests = kind === "deposit" ? state.deposits : state.withdrawals;
      list.innerHTML = requests.map((record) => requestMarkup(record, kind)).join("") ||
        `<div class="empty-state"><strong>No ${escapeText(kind)} history yet</strong><span>Wallet activity will appear here.</span></div>`;
    });
    const pageLabel = document.querySelector("[data-history-page]");
    if (pageLabel) pageLabel.textContent = `Page ${state.historyPage + 1}`;
    document.querySelector("[data-history-prev]").disabled = state.historyPage === 0;
    document.querySelector("[data-history-next]").disabled = !state.historyHasNext;
  }

  function requestMarkup(request, kind) {
    const status = String(request.status || "pending").toLowerCase();
    const succeeded = ["approved", "completed"].includes(status);
    const statusClass = succeeded ? "success" : ["rejected", "expired", "failed"].includes(status) ? "failed" : "pending";
    const amountPrefix = kind === "withdrawal" ? "−" : succeeded ? "+" : "*";
    const date = request.created_at
      ? new Date(request.created_at).toLocaleDateString("en-NG", { day: "numeric", month: "short" })
      : "—";
    const details = kind === "deposit"
      ? request.admin_note || request.user_note || "Deposit request"
      : [request.account_name, request.bank_name, `Account ending ${request.account_last4}`, request.admin_note].filter(Boolean).join(" · ");
    const reference = request.proof_path
      ? `<button class="text-link receipt-link" data-receipt-path="${escapeText(request.proof_path)}">View receipt</button>`
      : "";
    return `<article class="activity-row financial-request-row" data-kind="${kind}"><span class="activity-icon ${kind}">${kind === "deposit" ? "↓" : "↑"}</span><span class="activity-copy"><b>${kind === "deposit" ? "Deposit request" : "Withdrawal request"}</b><small>${escapeText(date)} <i class="activity-status ${statusClass}">${escapeText(status)}</i></small><small class="request-note">${escapeText(details)}</small>${reference}</span><span class="activity-amount ${succeeded && kind === "deposit" ? "incoming" : ""}">${amountPrefix}${money(request.amount)}</span></article>`;
  }

  async function loadTransactions(page = 0) {
    try {
      state.historyPage = page;
      const filters = {};
      const historyScreen = document.querySelector('[data-screen="history"]');
      if (historyScreen.classList.contains("active")) {
        const type = historyScreen.querySelector(".record-tab.selected")?.dataset.recordFilter;
        const status = document.querySelector("[data-history-status]").value;
        const from = document.querySelector("[data-history-from]").value;
        const to = document.querySelector("[data-history-to]").value;
        if (type && type !== "all") filters.type = type;
        if (status) filters.status = status;
        if (from || to) {
          filters.created_at = {};
          if (from) filters.created_at.gte = `${from}T00:00:00Z`;
          if (to) filters.created_at.lte = `${to}T23:59:59.999Z`;
        }
      }
      const requestRecords = state.page === "wallet"
        ? Promise.all([
          finance.transactions.listDeposits(state.user.id),
          finance.transactions.listWithdrawals(state.user.id)
        ])
        : Promise.resolve([state.deposits, state.withdrawals]);
      const [records, [deposits, withdrawals]] = await Promise.all([
        finance.transactions.list(state.user.id, { page, filters }),
        requestRecords
      ]);
      state.transactions = records.slice(0, 50);
      state.deposits = deposits;
      state.withdrawals = withdrawals;
      state.historyHasNext = records.length > 50;
    } catch (error) {
      showToast(`Transaction history unavailable: ${error.message}`);
      state.transactions = [];
      state.deposits = [];
      state.withdrawals = [];
      state.historyHasNext = false;
    }
    renderActivity();
  }

  function renderPlans() {
    const list = document.querySelector("[data-vip-list]");
    if (!plans.length) {
      list.innerHTML = `<div class="empty-state"><strong>VIP plans unavailable</strong><span>Refresh to load the latest plan details.</span></div>`;
      return;
    }
    list.innerHTML = plans.map((plan) => {
      const active = Number(state.user?.vip_level) === Number(plan.level);
      const unavailable = Number(plan.level) <= Number(state.user?.vip_level || 0);
      return `<details class="vip-plan ${active ? "current" : ""}" ${active ? "open" : ""}><summary><span class="vip-number">${plan.level}</span><span class="vip-plan-heading"><b>VIP ${plan.level}${active ? " · Current plan" : ""}</b><small>${plan.daily_tasks} ${plan.daily_tasks === 1 ? "daily task" : "daily tasks"}</small></span><span class="vip-cost">${money(plan.upgrade_cost, 2)}<small>UPGRADE COST</small></span><span class="vip-chevron">›</span></summary><div class="vip-plan-details"><div class="vip-detail-grid"><div class="vip-detail"><span>Daily tasks</span><b>${plan.daily_tasks}</b></div><div class="vip-detail"><span>Single task commission</span><b>${money(plan.task_commission)}</b></div><div class="vip-detail daily"><span>Daily income if all tasks are completed</span><b>${money(plan.daily_income)}</b></div></div><button class="button button-orange vip-upgrade ${active ? "current-button" : ""}" data-action="upgrade" data-plan="${plan.level}" ${unavailable ? "disabled" : ""}>${active ? "Current level" : unavailable ? "Already eligible" : "Pay with bank transfer"}</button></div></details>`;
    }).join("");
  }

  function clearTaskMedia() {
    window.clearTimeout(state.taskMediaTimer);
    window.clearInterval(state.taskMediaCountdown);
    state.taskMediaTimer = 0;
    state.taskMediaCountdown = 0;
    state.activeTaskMediaAttempt = null;
    const mediaBanner = document.querySelector("[data-task-media]");
    mediaBanner.classList.add("hidden");
    mediaBanner.classList.remove("fading");
    mediaBanner.replaceChildren();
  }

  async function showTaskMedia(tasks) {
    clearTaskMedia();
    const mediaTasks = tasks.filter((item) =>
      item.media_path && !state.completedTaskIds.has(item.id) && !state.taskMediaAttempts.has(item.id)
    );
    if (!mediaTasks.length || !state.activeTaskLimit ||
        state.completedTaskIds.size >= state.activeTaskLimit) return;
    const mediaBanner = document.querySelector("[data-task-media]");
    let index = 0;
    const showNext = async () => {
      if (state.page !== "tasks" || index >= mediaTasks.length) { clearTaskMedia(); return; }
      const task = mediaTasks[index++];
      try {
        const url = await db.createSignedUrl("task-media", task.media_path, 60);
        if (state.page !== "tasks") return;
        const media = document.createElement(task.media_path.match(/\.(mp4|webm|mov)$/i) ? "video" : "img");
        media.alt = `Task media: ${task.title}`;
        if (media instanceof HTMLVideoElement) {
          media.autoplay = true;
          media.muted = true;
          media.playsInline = true;
        }
        await new Promise((resolve, reject) => {
          media.addEventListener(media instanceof HTMLVideoElement ? "loadeddata" : "load", resolve, { once: true });
          media.addEventListener("error", () => reject(new Error("Task image or video could not be loaded.")), { once: true });
          media.src = url;
        });
        if (state.page !== "tasks") return;
        const attempt = await finance.taskMedia.begin(task.id);
        if (state.page !== "tasks") return;
        const tapTarget = document.createElement("button");
        tapTarget.type = "button";
        tapTarget.className = "task-media-challenge";
        tapTarget.dataset.action = "touch-task-media";
        tapTarget.dataset.attempt = attempt.attempt_id;
        const prompt = document.createElement("span");
        prompt.className = "task-media-countdown";
        prompt.textContent = "Tap the image or video within 10 seconds";
        prompt.setAttribute("role", "status");
        prompt.setAttribute("aria-live", "assertive");
        tapTarget.append(media, prompt);
        mediaBanner.replaceChildren(tapTarget);
        mediaBanner.classList.remove("hidden", "fading");
        state.activeTaskMediaAttempt = attempt.attempt_id;
        const deadline = Date.parse(attempt.started_at) + 10000;
        let recorded = false;
        let tapPending = false;
        const updateCountdown = () => {
          const remaining = Math.max(0, deadline - Date.now());
          prompt.textContent = `TAP NOW · ${(remaining / 1000).toFixed(1)}s`;
        };
        state.taskMediaCountdown = window.setInterval(updateCountdown, 100);
        state.taskMediaTimer = window.setTimeout(() => {
          window.clearInterval(state.taskMediaCountdown);
          state.taskMediaCountdown = 0;
          mediaBanner.classList.add("fading");
          state.taskMediaTimer = window.setTimeout(async () => {
            if (!recorded) {
              try {
                await finance.taskMedia.finish(attempt.attempt_id, false);
                recorded = true;
                showToast("Time is up. You can try this task again tomorrow.");
              } catch (error) {
                showToast(`Missed task could not be recorded: ${error.message}`);
              }
            }
            if (state.activeTaskMediaAttempt === attempt.attempt_id) state.activeTaskMediaAttempt = null;
            await loadTasks();
          }, 650);
        }, Math.max(0, deadline - Date.now()));
        tapTarget.addEventListener("click", async () => {
          if (tapPending || recorded || !state.activeTaskMediaAttempt) return;
          tapPending = true;
          tapTarget.disabled = true;
          try {
            const outcome = await finance.taskMedia.finish(attempt.attempt_id, Date.now() <= deadline);
            recorded = true;
            if (outcome.status === "completed") {
              state.completedTaskIds.add(task.id);
              prompt.textContent = "Task completed";
              showToast(`Task completed. ${money(outcome.reward_amount)} added to your wallet.`);
              await Promise.all([loadWallet(), loadTransactions()]);
            } else {
              prompt.textContent = "Time is up · try again tomorrow";
              showToast("This task attempt was not completed. You can try again tomorrow.");
            }
          } catch (error) {
            showToast(`Task attempt could not be saved: ${error.message}`);
          }
        });
      } catch (error) {
        showToast(error.message || "Task media unavailable.");
        state.taskMediaTimer = window.setTimeout(showNext, 0);
      }
    };
    await showNext();
  }

  async function loadTasks() {
    try {
      const todayParts = new Map(new Intl.DateTimeFormat("en-US", {
        timeZone: "Africa/Lagos", year: "numeric", month: "2-digit", day: "2-digit"
      }).formatToParts(new Date()).map((part) => [part.type, part.value]));
      const today = `${todayParts.get("year")}-${todayParts.get("month")}-${todayParts.get("day")}`;
      const [tasks, completions, attempts] = await Promise.all([
        db.select("tasks", { columns: "id,title,description,reward_amount,active,media_path,deleted_at", filters: { active: true, deleted_at: { is: "null" } }, order: "created_at.asc" }),
        db.select("task_completions", { columns: "task_id,reward_amount,task_date", filters: { user_id: state.user.id, task_date: today } }),
        db.select("task_media_attempts", { columns: "task_id,status,task_date", filters: { user_id: state.user.id, task_date: today } })
      ]);
      state.tasks = tasks;
      state.completedTaskIds = new Set(completions.map((item) => item.task_id));
      state.taskMediaAttempts = new Map(attempts.map((attempt) => [attempt.task_id, attempt.status]));
      const earned = completions.reduce((sum, item) => sum + Number(item.reward_amount), 0);
      const percent = state.activeTaskLimit ? Math.min(100, Math.round(completions.length / state.activeTaskLimit * 100)) : 0;
      document.querySelector("[data-daily-earnings]").textContent = money(earned);
      document.querySelector("[data-task-count]").textContent = String(completions.length);
      document.querySelector("[data-task-limit]").textContent = String(state.activeTaskLimit);
      document.querySelector("[data-home-task-count]").textContent = String(completions.length);
      document.querySelector("[data-home-task-limit]").textContent = String(state.activeTaskLimit);
      document.querySelector("[data-task-percent]").textContent = String(percent);
      document.querySelector("[data-progress-bar]").style.width = `${percent}%`;
      document.querySelector("[data-progress-copy]").textContent = state.activeTaskLimit
        ? completions.length >= state.activeTaskLimit ? "You have completed all tasks for today." : "Keep going to finish today's tasks."
        : "Choose an active VIP plan to unlock daily tasks.";
      const taskInstructions = document.querySelector(".task-disclaimer");
      taskInstructions.classList.remove("hidden");
      taskInstructions.querySelector("p").textContent = state.activeTaskLimit
        ? "VIP members only: tap the image or video as soon as it appears. You have 10 seconds; if you miss it, wait until tomorrow to try again."
        : "An active VIP plan is required to start or earn from any task. Non-VIP members cannot complete tasks. Choose an active VIP plan to unlock tasks.";
      const taskList = document.querySelector("[data-task-list]");
      taskList.innerHTML = tasks.length ? tasks.map((task) => {
        const complete = state.completedTaskIds.has(task.id);
        const limitReached = completions.length >= state.activeTaskLimit;
        const locked = !state.activeTaskLimit || (!complete && limitReached);
        const mediaAttempt = state.taskMediaAttempts.get(task.id);
        const mediaTask = Boolean(task.media_path);
        const taskStatus = complete ? "Completed today"
          : mediaAttempt === "missed" || mediaAttempt === "started" ? "Missed today · try again tomorrow"
            : mediaAttempt === "completed" ? "Completed today"
              : !state.activeTaskLimit ? "VIP plan required"
                : limitReached ? "Daily limit reached"
                  : mediaTask ? "Tap image or video within 10 seconds" : "Available today";
        const taskButton = mediaTask
          ? `<button class="task-start" disabled>${complete || mediaAttempt === "completed" ? "Done" : mediaAttempt ? "Try tomorrow" : !state.activeTaskLimit ? "VIP required" : limitReached ? "Daily limit" : "Tap media above"}</button>`
          : `<button class="task-start" data-action="complete-task" data-task="${escapeText(task.id)}" ${complete || locked ? "disabled" : ""}>${complete ? "Done" : !state.activeTaskLimit ? "VIP required" : limitReached ? "Daily limit" : "Start task"}</button>`;
        return `<article class="task-card"><div class="task-card-top"><span class="task-badge">${complete ? "✓" : "▣"}</span><div class="task-content"><h2>${escapeText(task.title)}</h2><p>${escapeText(task.description)}</p></div><span class="task-reward">${money(task.reward_amount)}<small>task reward</small></span></div><div class="task-card-bottom"><span class="task-status ${complete ? "completed" : ""}">${escapeText(taskStatus)}</span>${taskButton}</div></article>`;
      }).join("") : `<div class="empty-state"><strong>No tasks available</strong><span>Check back later for new tasks.</span></div>`;
      if (state.page === "tasks") await showTaskMedia(tasks);
      else clearTaskMedia();
    } catch (error) {
      showToast(`Tasks unavailable: ${error.message}`);
      document.querySelector("[data-daily-earnings]").textContent = "—";
      document.querySelector("[data-task-count]").textContent = "—";
      document.querySelector("[data-task-limit]").textContent = "—";
      document.querySelector("[data-home-task-count]").textContent = "—";
      document.querySelector("[data-home-task-limit]").textContent = "—";
      document.querySelector("[data-task-percent]").textContent = "—";
      document.querySelector("[data-progress-bar]").style.width = "0%";
      document.querySelector("[data-task-list]").innerHTML =
        `<div class="empty-state"><strong>Couldn't load tasks</strong><span>${escapeText(error.message)}</span></div>`;
    }
  }

  async function loadReferralData() {
    try {
      const [rows, rewardRates] = await Promise.all([
        db.select("referrals", { columns: "level,earnings,reward_amount,reward_paid_at", filters: { referrer_id: state.user.id } }),
        db.select("vip_referral_reward_rates", { columns: "level,reward_amount", order: "level.asc" })
      ]);
      state.referralLink = `${currentPath}?ref=${encodeURIComponent(state.user.referral_code)}`;
      document.querySelector("[data-referral-link]").textContent = state.referralLink;
      document.querySelector("[data-referral-code]").textContent = state.user.referral_code;
      document.querySelector('[data-action="copy-referral"]').disabled = false;
      document.querySelector("[data-vip-referral-reward-list]").innerHTML = rewardRates.map((rate) =>
        `<article><span class="level-badge level-one">VIP ${Number(rate.level)}</span><span><b>VIP ${Number(rate.level)} purchase</b><small>Paid after admin approves the payment</small></span><strong>${money(rate.reward_amount)}</strong></article>`
      ).join("") || `<p class="helper-text">VIP referral rewards are not configured yet.</p>`;
      const earnings = rows.filter((row) => Number(row.level) === 1)
        .reduce((sum, row) => sum + Number(row.earnings), 0);
      const counts = [1, 2, 3].map((level) => rows.filter((row) => Number(row.level) === level).length);
      document.querySelector("[data-team-count]").textContent = String(rows.length);
      document.querySelector("[data-team-earnings]").textContent = money(earnings);
      document.querySelector('[data-level-earnings="1"]').textContent = money(earnings);
      document.querySelector(".referral-link-card .helper-text").textContent =
        `Level 1: ${counts[0]} · Level 2: ${counts[1]} · Level 3: ${counts[2]}`;
    } catch (error) {
      showToast(`Referral information unavailable: ${error.message}`);
    }
  }

  async function startDashboard(user) {
    if (!user?.id) {
      showPublicPage("login");
      return;
    }
    const profile = await db.select("profiles", { columns: "id,role", filters: { id: user.id }, single: true });
    if (!profile || profile.role !== "user") {
      await db.signOut();
      showToast("This account cannot access the member dashboard.");
      showPublicPage("login");
      return;
    }
    state.user = { id: user.id };
    publicHome.hidden = true;
    authScreens.forEach((screen) => { screen.hidden = true; });
    app.hidden = false;
    window.history.replaceState(null, "", currentPath);
    setTodayLabels();
    setPage("home", false);
    await loadProfile();
    await Promise.all([loadWallet(), loadTransactions(), loadTasks()]);
  }

  function setTodayLabels() {
    const today = new Date();
    document.querySelector("[data-today-label]").textContent =
      today.toLocaleDateString("en-NG", { weekday: "long", day: "numeric", month: "long" }).toUpperCase();
    document.querySelector("[data-today-short]").textContent =
      today.toLocaleDateString("en-NG", { day: "numeric", month: "short" }).toUpperCase();
    document.querySelector("[data-year]").textContent = String(today.getFullYear());
  }

  function openMore() {
    moreSheet.classList.add("open");
    moreSheet.setAttribute("aria-hidden", "false");
  }

  function closeMore() {
    moreSheet.classList.remove("open");
    moreSheet.setAttribute("aria-hidden", "true");
  }

  async function openPayment(action, planLevel) {
    const isWithdrawal = action === "withdraw";
    const isDeposit = action === "deposit";
    const isVip = action === "vip";
    const selectedPlan = isVip ? plans.find((plan) => Number(plan.level) === Number(planLevel)) : null;
    if (isVip && (!selectedPlan || Number(planLevel) <= Number(state.user?.vip_level || 0))) {
      showToast("Choose an available VIP plan above your current level.");
      return;
    }
    document.querySelector("#modal-title").textContent = isWithdrawal ? "Request a withdrawal" : isVip ? `VIP ${selectedPlan.level} payment` : "Deposit request";
    document.querySelector(".modal-copy").textContent = isWithdrawal
      ? "Your requested amount is reserved while pending. Rejected requests are returned to your wallet."
      : isVip
        ? `Enter your account details to generate payment instructions for VIP ${selectedPlan.level}.`
        : "Enter your details and amount to view deposit instructions.";
    document.querySelector(".withdrawal-modal-fields").classList.toggle("hidden", !isWithdrawal);
    document.querySelector(".deposit-modal-fields").classList.toggle("hidden", !(isDeposit || isVip));
    document.querySelector("[data-deposit-amount-entry]").classList.remove("hidden");
    document.querySelector("[data-deposit-loading]").classList.add("hidden");
    document.querySelector("[data-payment-details]").classList.add("hidden");
    document.querySelector("[data-payment-feedback]").textContent = "";
    document.querySelector("[data-confirm-manual-payment]").disabled = false;
    document.querySelector("[data-confirm-manual-payment]").textContent =
      isVip ? "I have paid for this VIP plan" : "I have made the payment";
    document.querySelector(".amount-label").textContent = isWithdrawal ? "Withdrawal amount (₦)" : isVip ? "Selected plan price (₦)" : "Deposit amount (₦)";
    document.querySelector("#deposit-full-name").required = isDeposit || isVip;
    document.querySelector("#deposit-phone").required = isDeposit || isVip;
    document.querySelector("#deposit-full-name").value = state.user?.full_name || "";
    document.querySelector("#deposit-phone").value = state.user?.phone || "";
    document.querySelector("#withdraw-bank-name").required = isWithdrawal;
    document.querySelector("#withdraw-account-name").required = isWithdrawal;
    document.querySelector("#withdraw-account-number").required = isWithdrawal;
    paymentAmount.value = isVip ? Number(selectedPlan.upgrade_cost).toFixed(2) : "";
    paymentAmount.disabled = false;
    paymentAmount.readOnly = isVip;
    document.querySelector(".withdrawal-error").textContent = "";
    document.querySelector(".modal-note").textContent = isWithdrawal
      ? "Your requested amount is reserved from your SkeptiCash wallet. Rejected requests are refunded; approved payouts are made separately."
      : isVip
        ? "VIP payments are reviewed by an administrator and do not add money to your wallet."
        : "Your wallet is credited only after an administrator confirms the bank transfer.";
    const submit = document.querySelector(".modal-submit");
    submit.textContent = isWithdrawal ? "Submit withdrawal request" : isVip ? "Generate VIP payment details" : "Continue";
    submit.disabled = false;
    submit.classList.remove("withdrawal-closed");
    submit.classList.remove("hidden");
    document.querySelector("#modal-title").textContent = isWithdrawal ? "Withdrawal request" : isVip ? `VIP ${selectedPlan.level} payment` : "Deposit request";
    state.action = isWithdrawal ? "withdrawal" : isVip ? "vip" : "deposit";
    state.vipPlanLevel = isVip ? Number(selectedPlan.level) : null;
    state.depositStage = "form";
    state.activeDepositId = null;
    state.activeVipRequestId = null;
    window.clearInterval(state.depositCountdown);
    state.depositCountdown = 0;
    modal.classList.add("open");
    modal.setAttribute("aria-hidden", "false");
    if (isWithdrawal) {
      try {
        state.withdrawalDays = await finance.withdrawals.allowedDays();
        updateWithdrawalAvailability(submit);
      } catch (error) {
        submit.disabled = true;
        document.querySelector(".withdrawal-error").textContent = `Withdrawal schedule unavailable: ${error.message}`;
      }
    }
  }

  function updateWithdrawalAvailability(submit = document.querySelector(".modal-submit")) {
    const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const allowedDays = state.withdrawalDays;
    if (!Array.isArray(allowedDays) || !allowedDays.length) {
      submit.disabled = true;
      submit.classList.add("withdrawal-closed");
      document.querySelector(".withdrawal-error").textContent = "Withdrawal days are not configured. Please contact support.";
      return false;
    }

    const parts = new Map(new Intl.DateTimeFormat("en-US", {
      timeZone: "Africa/Lagos", weekday: "long", year: "numeric", month: "2-digit", day: "2-digit"
    }).formatToParts(new Date()).map((part) => [part.type, part.value]));
    const todayName = parts.get("weekday");
    const todayIndex = dayNames.indexOf(todayName);
    const todayDate = Date.UTC(Number(parts.get("year")), Number(parts.get("month")) - 1, Number(parts.get("day")));
    const allowedNames = allowedDays.map((day) => dayNames[day]);
    const dayIsOpen = allowedDays.includes(todayIndex);
    document.querySelector(".withdrawal-error").textContent = "";

    if (dayIsOpen) {
      submit.disabled = false;
      submit.classList.remove("withdrawal-closed");
      document.querySelector(".modal-note").textContent =
        `Withdrawals are open today (${todayName}). Your wallet amount is reserved while pending.`;
      return true;
    }

    const nextOffset = Array.from({ length: 7 }, (_, index) => index + 1)
      .find((offset) => allowedDays.includes((todayIndex + offset) % 7));
    const nextDate = new Date(todayDate + nextOffset * 86400000);
    const nextDayName = dayNames[(todayIndex + nextOffset) % 7];
    const nextDateLabel = new Intl.DateTimeFormat("en-NG", {
      timeZone: "UTC", day: "numeric", month: "long"
    }).format(nextDate);
    submit.disabled = true;
    submit.classList.add("withdrawal-closed");
    document.querySelector(".modal-note").textContent =
      `Withdrawals open on: ${allowedNames.join(", ")}.`;
    document.querySelector(".withdrawal-error").textContent =
      `Withdrawals are closed today (${todayName}). Please wait until ${nextDayName}, ${nextDateLabel} to submit your request.`;
    return false;
  }

  function closePayment() {
    window.clearInterval(state.depositCountdown);
    state.depositCountdown = 0;
    state.activeDepositId = null;
    state.activeVipRequestId = null;
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden", "true");
    paymentForm.reset();
  }

  function showDepositDetails(details, paymentRequest, isVip = false) {
    document.querySelector("[data-payment-account-name]").textContent = details.account_name;
    document.querySelector("[data-payment-account-number]").textContent = details.account_number;
    document.querySelector("[data-payment-bank-name]").textContent = details.bank_name;
    document.querySelector("[data-payment-instruction]").textContent = details.instruction || "No additional instruction provided.";
    document.querySelector("[data-deposit-amount]").textContent = money(paymentRequest.amount, isVip ? 2 : 0);
    document.querySelector("[data-payment-amount-label]").textContent = isVip
      ? `Pay for VIP ${state.vipPlanLevel} · exact plan amount`
      : "Deposit amount";
    document.querySelector("[data-deposit-amount-entry]").classList.add("hidden");
    document.querySelector(".deposit-modal-fields").classList.add("hidden");
    document.querySelector("[data-deposit-loading]").classList.add("hidden");
    document.querySelector("[data-payment-details]").classList.remove("hidden");
    document.querySelector(".modal-submit").classList.add("hidden");
    document.querySelector("#modal-title").textContent = isVip ? "Complete your VIP payment" : "Complete your bank transfer";
    state.activeDepositId = isVip ? null : paymentRequest.id;
    state.activeVipRequestId = isVip ? paymentRequest.id : null;
    state.depositStage = "details";
    document.querySelector("[data-confirm-manual-payment]").textContent =
      isVip ? "I have paid for this VIP plan" : "I have made the payment";
    state.depositCountdown = window.setInterval(() => updateDepositCountdown(paymentRequest.expires_at), 1000);
    updateDepositCountdown(paymentRequest.expires_at);
  }

  function updateDepositCountdown(expiresAt) {
    const remaining = Math.max(0, Math.ceil((Date.parse(expiresAt) - Date.now()) / 1000));
    const minutes = String(Math.floor(remaining / 60)).padStart(2, "0");
    const seconds = String(remaining % 60).padStart(2, "0");
    document.querySelector("[data-deposit-countdown]").textContent = `${minutes}:${seconds}`;
    if (remaining === 0) void expireActiveDeposit();
  }

  async function expireActiveDeposit() {
    const depositId = state.activeDepositId;
    const vipRequestId = state.activeVipRequestId;
    if (!depositId && !vipRequestId) return;
    state.activeDepositId = null;
    state.activeVipRequestId = null;
    window.clearInterval(state.depositCountdown);
    state.depositCountdown = 0;
    let expireError = null;
    try {
      if (vipRequestId) await finance.vip.expire(vipRequestId);
      else await finance.deposits.expire(depositId);
    } catch (error) {
      expireError = error;
      showToast(`Could not close the expired deposit request: ${error.message}`);
    }
    closePayment();
    if (!expireError) {
      showToast(vipRequestId ? "VIP payment request expired. Start again to generate new payment details." : "Payment request expired. Start a new request if you still want to deposit.");
    }
    if (depositId) await Promise.all([loadWallet(), loadTransactions(0)]);
    else if (vipRequestId) await loadTransactions(0);
  }

  async function copyPaymentDetail(button) {
    const values = {
      "payment-amount": document.querySelector("[data-deposit-amount]").textContent,
      "account-name": document.querySelector("[data-payment-account-name]").textContent,
      "account-number": document.querySelector("[data-payment-account-number]").textContent,
      "bank-name": document.querySelector("[data-payment-bank-name]").textContent
    };
    const value = values[button.dataset.copyPayment];
    if (!value) return;
    await navigator.clipboard.writeText(value);
    showToast("Copied Successfully");
  }

  function prepareWithdrawalFields() {
    document.querySelector(".withdrawal-modal-fields").innerHTML =
      '<label class="field-label" for="withdraw-account-name">Account holder name</label>' +
      '<input id="withdraw-account-name" name="accountName" type="text" maxlength="160" autocomplete="name" required>' +
      '<label class="field-label" for="withdraw-account-number">Account number</label>' +
      '<input id="withdraw-account-number" name="accountNumber" type="text" inputmode="numeric" pattern="[0-9\\s-]{10,24}" maxlength="24" autocomplete="off" required>' +
      '<label class="field-label" for="withdraw-bank-name">Bank name</label>' +
      '<input id="withdraw-bank-name" name="bankName" type="text" maxlength="100" autocomplete="organization" required>';
  }

  async function confirmManualPayment(button) {
    const isVip = state.action === "vip";
    const requestId = isVip ? state.activeVipRequestId : state.activeDepositId;
    if (!requestId) return;
    button.disabled = true;
    try {
      const result = isVip
        ? await finance.vip.confirm(requestId)
        : await finance.deposits.confirmPayment(requestId);
      if (!result?.payment_submitted_at || result.status !== "pending") {
        throw new Error("The payment confirmation was not saved. Refresh your deposit history and try again.");
      }
      window.clearInterval(state.depositCountdown);
      state.depositCountdown = 0;
      state.activeDepositId = null;
      state.activeVipRequestId = null;
      closePayment();
      showToast(isVip
        ? "VIP payment reported to the admin. Your plan will update after payment verification."
        : "Payment reported to the admin. Your deposit is awaiting verification.");
      if (isVip) await loadTransactions(0);
      else await Promise.all([loadWallet(), loadTransactions(0)]);
    } catch (error) {
      document.querySelector("[data-payment-feedback]").textContent = error.message;
      button.disabled = false;
    }
  }

  async function submitWalletRequest(event) {
    const submit = document.querySelector(".modal-submit");
    const error = document.querySelector(".withdrawal-error");
    const data = new FormData(paymentForm);
    const amount = Number(data.get("amount"));
    if (["deposit", "vip"].includes(state.action) && state.depositStage !== "form") return;
    if (state.action === "withdrawal" && !updateWithdrawalAvailability(submit)) {
      error.textContent = document.querySelector(".modal-note").textContent;
      return;
    }
    if (!Number.isFinite(amount) || (state.action === "vip" ? amount <= 0 : amount < 100) || amount > 999999999999.99) {
      error.textContent = state.action === "vip" ? "The selected VIP price is invalid." : "Enter an amount of at least ₦100.";
      return;
    }
    submit.disabled = true;
    error.textContent = "";
    try {
      if (state.action === "deposit" || state.action === "vip") {
        const isVip = state.action === "vip";
        state.depositStage = "loading";
        document.querySelector("#modal-title").textContent = isVip ? "Preparing VIP payment" : "Preparing your payment";
        document.querySelector("[data-deposit-amount-entry]").classList.add("hidden");
        document.querySelector(".deposit-modal-fields").classList.add("hidden");
        document.querySelector("[data-deposit-loading]").classList.remove("hidden");
        submit.classList.add("hidden");
        await new Promise((resolve) => window.setTimeout(resolve, 5000));
        const details = await finance.deposits.getManualDetails();
        if (isVip) {
          const request = await finance.vip.create({
            planLevel: state.vipPlanLevel,
            fullName: data.get("fullName"),
            phone: data.get("phone")
          });
          showDepositDetails(details, request, true);
          await loadTransactions(0);
        } else {
          const deposit = await finance.deposits.createManual({
            fullName: data.get("fullName"),
            phone: data.get("phone"),
            amount
          });
          showDepositDetails(details, deposit);
          await Promise.all([loadWallet(), loadTransactions(0)]);
        }
        return;
      } else if (state.action === "withdrawal") {
        await finance.withdrawals.request({
          amount,
          bankName: data.get("bankName"),
          accountName: data.get("accountName"),
          accountNumber: data.get("accountNumber")
        });
        showToast("Withdrawal request submitted. The amount is reserved while the request is pending.");
      }
      closePayment();
      await Promise.all([loadWallet(), loadTransactions(0)]);
      if (state.page === "history") state.historyPage = 0;
    } catch (failure) {
      if (state.action === "withdrawal" && /configured withdrawal day|withdrawals can only be requested/i.test(failure.message)) {
        try {
          state.withdrawalDays = await finance.withdrawals.allowedDays();
          updateWithdrawalAvailability(submit);
          error.textContent = document.querySelector(".modal-note").textContent;
        } catch (scheduleError) {
          state.withdrawalDays = null;
          submit.disabled = true;
          error.textContent = `Withdrawal schedule unavailable: ${scheduleError.message}`;
        }
      } else {
        error.textContent = failure.message;
      }
      if (["deposit", "vip"].includes(state.action) && state.depositStage === "loading") {
        state.depositStage = "form";
        document.querySelector("#modal-title").textContent = state.action === "vip" ? `VIP ${state.vipPlanLevel} payment` : "Deposit request";
        document.querySelector("[data-deposit-amount-entry]").classList.remove("hidden");
        document.querySelector(".deposit-modal-fields").classList.remove("hidden");
        document.querySelector("[data-deposit-loading]").classList.add("hidden");
        submit.classList.remove("hidden");
      }
    } finally {
      if (state.action === "withdrawal" && modal.classList.contains("open")) {
        updateWithdrawalAvailability(submit);
      } else {
        submit.disabled = false;
      }
    }
  }

  async function completeTask(taskId, button) {
    button.disabled = true;
    try {
      await db.rpc("complete_task", { p_task_id: taskId });
      showToast("Task completed and earnings added to your wallet.");
      await Promise.all([loadTasks(), loadWallet(), loadTransactions()]);
    } catch (error) {
      showToast(`Couldn't complete task: ${error.message}`);
      button.disabled = false;
    }
  }

  async function copyReferral() {
    if (!state.referralLink) return;
    await navigator.clipboard.writeText(state.referralLink);
    showToast("Referral link copied.");
  }

  async function handleAction(action, button) {
    if (action === "more") openMore();
    else if (action === "wallet") setPage("wallet");
    else if (action === "tasks") setPage("tasks");
    else if (action === "team") setPage("team");
    else if (action === "deposit" || action === "withdraw") await openPayment(action);
    else if (action === "upgrade") openPayment("vip", button.dataset.plan);
    else if (action === "touch-task-media") return;
    else if (action === "complete-task") await completeTask(button.dataset.task, button);
    else if (action === "copy-referral") {
      try { await copyReferral(); }
      catch (error) { showToast(`Couldn't copy referral link: ${error.message}`); }
    } else if (action === "share-referral") {
      try {
        if (navigator.share) await navigator.share({ title: "Join me on SkeptiCash", url: state.referralLink });
        else await copyReferral();
      } catch (error) {
        if (error.name !== "AbortError") showToast(`Couldn't share referral link: ${error.message}`);
      }
    } else if (action === "logout") {
      try {
        await db.signOut();
        state.user = null;
        showPublicPage("home");
      } catch (error) { showToast(`Couldn't log out: ${error.message}`); }
    } else if (action === "security") {
      const currentPassword = window.prompt("Enter your current password");
      if (currentPassword === null) return;
      const newPassword = window.prompt("Enter a new password (at least 8 characters)");
      if (newPassword === null) return;
      const confirmedPassword = window.prompt("Confirm your new password");
      if (confirmedPassword === null) return;
      if (newPassword !== confirmedPassword) {
        showToast("The new passwords do not match.");
        return;
      }
      try {
        await db.changePassword({ currentPassword, newPassword });
        state.user = null;
        showPublicPage("login");
        showToast("Password changed. Sign in with your new password.");
      } catch (error) { showToast(`Couldn't change password: ${error.message}`); }
    } else if (action === "personal-details") {
      const nextName = window.prompt("Enter your full name", state.user.full_name);
      if (nextName === null || !nextName.trim()) return;
      try {
        await db.update("profiles", { id: state.user.id }, { full_name: nextName.trim() }, { returning: false });
        await loadProfile();
        showToast("Profile updated.");
      } catch (error) { showToast(`Couldn't update profile: ${error.message}`); }
    } else if (action === "bank-account") {
      showToast("Saved bank details are not enabled yet.");
    } else if (action === "notifications") {
      try {
        const rows = await db.select("announcements", { columns: "title,body", filters: { active: true }, order: "created_at.desc", limit: 1 });
        showToast(rows.length ? `${rows[0].title}: ${rows[0].body}` : "You’re all caught up.");
      } catch (error) { showToast(`Announcements unavailable: ${error.message}`); }
    }
  }

  async function handleAuthForm(form) {
    const data = new FormData(form);
    const feedback = form.querySelector(".auth-feedback");
    const submit = form.querySelector('[type="submit"]');
    const originalButtonContent = submit.innerHTML;
    const loadingLabels = { login: "Signing in...", register: "Creating account..." };
    feedback.textContent = "";
    submit.disabled = true;
    submit.classList.add("is-loading");
    submit.setAttribute("aria-busy", "true");
    submit.textContent = loadingLabels[form.dataset.authForm] || "Please wait...";
    try {
      if (form.dataset.authForm === "login") {
        const session = await db.signIn({ phone: normalizePhoneNumber(data.get("phone")), password: data.get("password") });
        if (session.must_change_password) {
          const newPassword = window.prompt("You must replace your temporary password. Enter a new password (at least 8 characters).");
          if (newPassword === null) {
            await db.signOut();
            feedback.textContent = "A password change is required before you can continue.";
            return;
          }
          const confirmedPassword = window.prompt("Confirm your new password.");
          if (confirmedPassword === null || confirmedPassword !== newPassword) {
            await db.signOut();
            feedback.textContent = "The passwords did not match. Sign in again to restart the password change.";
            return;
          }
          await db.changePassword({ currentPassword: data.get("password"), newPassword });
          feedback.textContent = "Password changed. Please sign in again with your new password.";
          return;
        }
        await startDashboard(session.user);
      } else if (form.dataset.authForm === "register") {
        const referralCode = String(data.get("referralCode") || "").trim() ||
          new URLSearchParams(window.location.search).get("ref") || "";
        const signup = await db.signUp({
          phone: normalizePhoneNumber(data.get("phone")),
          password: data.get("password"),
          referralCode
        });
        if (signup.access_token) await startDashboard(signup.user);
        else feedback.textContent = "Account created, but sign-in could not be started. Please log in with your phone number and password.";
      }
    } catch (error) {
      feedback.textContent = form.dataset.authForm === "register" &&
        /phone signups are disabled/i.test(error.message)
        ? "Phone signup is disabled in Supabase. In your Supabase project, open Authentication → Sign In / Providers, enable the Phone provider, save, then try again. Keep phone confirmation disabled if you do not want SMS verification."
        : error.message;
    } finally {
      submit.disabled = false;
      submit.classList.remove("is-loading");
      submit.removeAttribute("aria-busy");
      submit.innerHTML = originalButtonContent;
    }
  }

  function normalizePhoneNumber(value) {
    let phone = String(value || "").trim().replace(/[\s()-]/g, "");
    if (/^0\d{10}$/.test(phone)) phone = `+234${phone.slice(1)}`;
    else if (/^234\d{10}$/.test(phone)) phone = `+${phone}`;
    if (!/^\+[1-9]\d{7,14}$/.test(phone)) {
      throw new Error("Enter a valid phone number, preferably in international format (for example, +2348012345678).");
    }
    return phone;
  }

  async function initialize() {
    prepareWithdrawalFields();
    document.querySelector('[data-auth-form="register"] [name="referralCode"]').value =
      new URLSearchParams(window.location.search).get("ref") || "";
    document.addEventListener("click", async (event) => {
      const publicButton = event.target.closest("[data-public-page]");
      if (publicButton) {
        event.preventDefault();
        if (publicButton.dataset.publicPage === "forgot" || publicButton.dataset.publicPage === "reset-password") {
          showToast("Contact an administrator to reset your password.");
          return;
        }
        showPublicPage(publicButton.dataset.publicPage);
        return;
      }
      const pageButton = event.target.closest("[data-page]");
      if (pageButton) {
        event.preventDefault();
        setPage(pageButton.dataset.page);
        return;
      }
      const actionButton = event.target.closest("[data-action]");
      if (actionButton) {
        event.preventDefault();
        await handleAction(actionButton.dataset.action, actionButton);
        return;
      }
      if (event.target.closest(".balance-visibility")) {
        state.hiddenBalance = !state.hiddenBalance;
        setBalanceVisibility();
      } else if (event.target.closest("[data-copy-payment]")) {
        const copyButton = event.target.closest("[data-copy-payment]");
        try { await copyPaymentDetail(copyButton); }
        catch (error) { showToast(`Could not copy account detail: ${error.message}`); }
      } else if (event.target.closest("[data-confirm-manual-payment]")) {
        await confirmManualPayment(event.target.closest("[data-confirm-manual-payment]"));
      } else if (event.target.closest("[data-receipt-path]")) {
        const receipt = event.target.closest("[data-receipt-path]");
        const receiptWindow = window.open("about:blank", "_blank");
        if (!receiptWindow) {
          showToast("Allow pop-ups to open your private receipt.");
          return;
        }
        receiptWindow.opener = null;
        try {
          const url = await finance.storage.createReceiptUrl(receipt.dataset.receiptPath);
          receiptWindow.location.href = url;
        } catch (error) {
          receiptWindow.close();
          showToast(`Receipt unavailable: ${error.message}`);
        }
      } else if (event.target.closest(".sheet-close") || event.target === moreSheet) {
        closeMore();
      } else if (event.target.closest(".modal-close") || event.target === modal) {
        closePayment();
      }
    });
    document.addEventListener("submit", async (event) => {
      const authForm = event.target.closest("[data-auth-form]");
      if (authForm) {
        event.preventDefault();
        await handleAuthForm(authForm);
      } else if (event.target === paymentForm) {
        event.preventDefault();
        await submitWalletRequest(event);
      }
    });
    document.addEventListener("click", (event) => {
      const filter = event.target.closest("[data-record-filter]");
      if (filter) {
        const parent = filter.closest(".record-tabs");
        parent.querySelectorAll("[data-record-filter]").forEach((tab) => {
          const selected = tab === filter;
          tab.classList.toggle("selected", selected);
          tab.setAttribute("aria-selected", String(selected));
        });
        if (state.page === "history") loadTransactions(0);
        else renderActivity();
        return;
      }
      if (event.target.closest("[data-history-prev]") && state.historyPage > 0) loadTransactions(state.historyPage - 1);
      if (event.target.closest("[data-history-next]") && state.historyHasNext) loadTransactions(state.historyPage + 1);
    });
    ["[data-history-from]", "[data-history-to]", "[data-history-status]"].forEach((selector) => {
      document.querySelector(selector).addEventListener("change", () => {
        if (state.page === "history") loadTransactions(0);
      });
    });
    window.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { closeMore(); closePayment(); }
    });

    document.querySelectorAll("[data-year]").forEach((element) => { element.textContent = String(new Date().getFullYear()); });
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && state.user && !app.hidden) loadWallet();
    });
    window.setInterval(() => {
      if (!document.hidden && state.user && !app.hidden) loadWallet();
    }, 60000);
    if (!db.isConfigured()) {
      showPublicPage("home");
      showToast("Supabase is not configured yet. Set the project URL and publishable key in supabase-config.js.");
      return;
    }
    try {
      const session = await db.getSession();
      if (session?.user?.id) await startDashboard(session.user);
      else {
        const requested = window.location.hash.slice(1);
        showPublicPage(["login", "register"].includes(requested) ? requested : "home");
      }
    } catch (error) {
      showPublicPage("home");
      showToast(`Could not initialize your account: ${error.message}`);
    }
  }

  initialize();
})();
