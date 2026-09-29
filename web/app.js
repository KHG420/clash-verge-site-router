(() => {
  'use strict';

  const state = {
    token: null,
    snapshot: null,
    view: 'overview',
    nodes: null,
    importDocument: null,
    importPreview: null,
    importNames: [],
    scenePreview: null,
    adoptionPreview: null,
    busy: false
  };

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const node = (tag, className, content) => {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (content !== undefined && content !== null) el.textContent = String(content);
    return el;
  };
  const append = (parent, ...children) => {
    children.flat().filter(Boolean).forEach(child => parent.append(child));
    return parent;
  };
  const clear = el => { el.replaceChildren(); return el; };
  const button = (label, className, onClick) => {
    const el = node('button', className, label);
    el.type = 'button';
    el.addEventListener('click', onClick);
    return el;
  };
  const p = (content, className = '') => node('p', className, content);
  const safeList = value => Array.isArray(value) ? value : [];
  const valueOrDash = value => value === null || value === undefined || value === '' ? '未知' : String(value);
  const date = value => {
    if (value === null || value === undefined || value === '') return '未知';
    const time = typeof value === 'number' || /^\d+(?:\.\d+)?$/.test(String(value)) ? Number(value) * 1000 : Date.parse(String(value));
    const d = new Date(time);
    return Number.isNaN(d.getTime()) ? '未知' : new Intl.DateTimeFormat('zh-CN', {year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit'}).format(d);
  };
  const quantity = value => Number.isFinite(Number(value)) && value !== null ? new Intl.NumberFormat('zh-CN', {maximumFractionDigits: 2}).format(Number(value)) : '未知';
  const bytes = value => Number.isFinite(Number(value)) && value !== null && value !== '' ? `${new Intl.NumberFormat('zh-CN', {maximumFractionDigits: 2}).format(Number(value) / 1024 ** 3)} GiB` : '未知';
  const actionAccepted = result => !!result && result.state !== 'error' && result.status !== 'error' && result.state !== 'partial' && result.status !== 'partial';
  const subscriptionName = uid => {
    const found = safeList(state.snapshot?.subscriptions).find(item => String(item.uid) === String(uid));
    return found?.alias || found?.name || String(uid || '未知订阅');
  };
  const detail = (label, value) => append(node('div', 'detail'), node('span', 'detail-label', label), node('strong', '', valueOrDash(value)));
  const empty = (title, message) => append(node('div', 'empty'), node('strong', '', title), p(message));
  const isEditing = () => {
    const active = document.activeElement;
    return !!$('.alias-editor') || !!$('form[data-editing="true"]') || !!(active && (active.matches('input, textarea, select') || active.isContentEditable));
  };

  function notifyChangedAlerts(alerts) {
    const key = 'verge-panel-alert-state';
    const current = Object.fromEntries(safeList(alerts).filter(item => item?.id).map(item => [String(item.id), {level: item.level || 'info', message: item.message || '', subscription: item.subscription || ''}]));
    let previous;
    try { previous = JSON.parse(sessionStorage.getItem(key)); } catch { previous = null; }
    const rank = {info: 1, warning: 2, error: 3, critical: 4};
    const changed = previous && typeof previous === 'object' ? safeList(alerts).filter(item => item?.id && (!previous[item.id] || (rank[item.level] || 0) > (rank[previous[item.id].level] || 0))) : [];
    sessionStorage.setItem(key, JSON.stringify(current));
    if (changed.length && window.Notification?.permission === 'granted') {
      const first = changed[0];
      const extra = changed.length > 1 ? `，另有 ${changed.length - 1} 条提醒` : '';
      try { new Notification('Verge 路由提醒', {body: `${first.subscription || '订阅'}：${first.message}${extra}`, tag: 'verge-panel-alerts'}); } catch { /* 浏览器可能禁止当前页面创建通知。 */ }
    }
  }

  function captureToken() {
    const fragment = new URLSearchParams(location.hash.replace(/^#/, ''));
    const token = fragment.get('token');
    if (token) sessionStorage.setItem('verge-panel-token', token);
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
    state.token = sessionStorage.getItem('verge-panel-token');
  }

  async function api(path, options = {}) {
    if (!state.token) throw new Error('缺少本地访问令牌。请从命令行重新打开管理页面。');
    const response = await fetch(path, {
      method: options.method || 'GET',
      headers: {'X-Verge-Token': state.token, ...(options.body ? {'Content-Type': 'application/json'} : {})},
      body: options.body ? JSON.stringify(options.body) : undefined,
      cache: 'no-store'
    });
    let payload;
    try { payload = await response.json(); }
    catch { throw new Error(`服务器返回了无法读取的响应（HTTP ${response.status}）。`); }
    if (!response.ok || !payload?.ok) throw new Error(payload?.error || `请求失败（HTTP ${response.status}）。`);
    return payload.data;
  }

  function setMessage(message, type = 'error') {
    const el = $('#global-message');
    el.className = `message ${type}`;
    el.textContent = message;
    el.classList.remove('hidden');
  }
  function hideMessage() { $('#global-message').classList.add('hidden'); }

  function renderResult(title, result) {
    const activity = $('#activity');
    const body = clear($('#activity-body'));
    const status = String(result?.status || result?.state || '');
    const label = status === 'awaiting_client' ? '等待客户端生效' : status === 'partial' ? '部分完成' : status === 'error' ? '操作未完成' : status === 'verified' || status === 'active' ? '已验证生效' : '操作结果已返回';
    append(body, node('span', `state-pill ${status === 'error' ? 'danger' : status === 'awaiting_client' || status === 'partial' ? 'warning' : status === 'verified' || status === 'active' ? 'success' : 'muted'}`, label), node('h2', '', title));
    if (result?.message) append(body, p(result.message));
    const pre = node('pre', 'result-json');
    pre.textContent = JSON.stringify(result ?? {}, null, 2);
    const details = node('details', 'result-details');
    append(details, node('summary', '', '查看完整结果'), pre);
    append(body, details);
    activity.classList.remove('hidden');
  }

  async function runAction(action, args, title, trigger) {
    if (state.busy) return null;
    state.busy = true;
    hideMessage();
    if (trigger) { trigger.disabled = true; trigger.dataset.originalLabel = trigger.textContent; trigger.textContent = '处理中…'; }
    try {
      const result = await api('/api/action', {method: 'POST', body: {action, args}});
      renderResult(title, result);
      if (trigger?.form && actionAccepted(result)) trigger.form.dataset.editing = 'false';
      try { await loadSnapshot({silent: true, preserveEdits: true}); }
      catch { setMessage('操作结果已返回，但无法重新读取最新配置。请点击“重新读取”核对。'); }
      return result;
    } catch (error) {
      setMessage(`${title}失败：${error.message}`);
      renderResult(title, {status: 'error', message: error.message});
      return null;
    } finally {
      state.busy = false;
      if (trigger) { trigger.disabled = false; trigger.textContent = trigger.dataset.originalLabel; }
    }
  }

  async function loadSnapshot({silent = false, preserveEdits = false} = {}) {
    try {
      const data = await api('/api/snapshot');
      state.snapshot = data;
      notifyChangedAlerts(data.alerts);
      $('#loading').classList.add('hidden');
      $('#content').classList.remove('hidden');
      $('#base-name').textContent = data.base?.name || '未命名配置';
      $('#sync-time').textContent = `读取于 ${new Intl.DateTimeFormat('zh-CN', {hour: '2-digit', minute: '2-digit'}).format(new Date())}`;
      hideMessage();
      if (!preserveEdits || !isEditing()) renderAll();
      return data;
    } catch (error) {
      $('#loading').classList.add('hidden');
      if (!state.snapshot) $('#content').classList.add('hidden');
      if (!silent || !state.snapshot) setMessage(`无法读取本地配置：${error.message} 请检查服务是否仍在运行，然后重新读取。`);
      throw error;
    }
  }

  function showView(view) {
    state.view = view;
    $$('.nav-item').forEach(item => {
      const active = item.dataset.view === view;
      item.classList.toggle('is-active', active);
      if (active) item.setAttribute('aria-current', 'page'); else item.removeAttribute('aria-current');
    });
    $$('.view').forEach(panel => panel.classList.toggle('hidden', panel.dataset.panel !== view));
    if (view === 'nodes') loadNodes();
    if (view === 'history') loadPlan();
    $('#main').focus({preventScroll: true});
    window.scrollTo({top: 0, behavior: 'instant'});
  }

  function renderAll() {
    renderSelects();
    renderOverview();
    renderRoutes();
    renderScenarios();
    renderHistory();
    renderAlerts();
  }

  function renderSelects() {
    $$('.subscription-select').forEach(select => {
      const previous = select.value;
      clear(select);
      const placeholder = node('option', '', '选择订阅');
      placeholder.value = '';
      append(select, placeholder);
      safeList(state.snapshot?.subscriptions).forEach(sub => {
        const option = node('option', '', sub.alias || sub.name || sub.uid);
        option.value = sub.uid;
        append(select, option);
      });
      if ([...select.options].some(option => option.value === previous)) select.value = previous;
      else if (select.id === 'nodes-subscription' && select.options.length > 1) select.selectedIndex = 1;
    });
  }

  function renderOverview() {
    const snapshot = state.snapshot;
    const status = snapshot.status || {};
    const banner = clear($('#status-banner'));
    banner.className = `status-banner ${status.state === 'active' || status.state === 'verified' ? 'is-good' : status.state === 'error' ? 'is-error' : 'is-waiting'}`;
    append(banner, node('span', 'status-light'), append(node('div'), node('strong', '', status.label || '状态未知'), p(status.message || '等待客户端状态。')), button('检查状态', 'button button-quiet', event => runAction('verify', {}, '检查客户端状态', event.currentTarget)));
    const filter = $('#subscription-search').value.trim().toLocaleLowerCase();
    const all = safeList(snapshot.subscriptions);
    const subs = all.filter(sub => [sub.name, sub.alias, ...safeList(sub.tags)].some(value => String(value || '').toLocaleLowerCase().includes(filter)));
    $('#subscription-count').textContent = `显示 ${subs.length} / ${all.length} 个订阅`;
    const list = clear($('#subscription-list'));
    if (!subs.length) { append(list, empty(all.length ? '没有匹配的订阅' : '尚未找到订阅', all.length ? '试试更短的名称或标签。' : '请先在 Clash Verge 中添加订阅，再重新读取。')); return; }
    subs.forEach(sub => {
      const row = node('article', 'subscription-record');
      const role = sub.role || '状态未知';
      const heading = append(node('div', 'record-heading'), node('h2', '', sub.alias || sub.name || sub.uid), node('span', `state-pill ${role === '主订阅' || role === '分流使用' ? 'success' : 'muted'}`, role));
      const meta = append(node('div', 'record-meta'), node('span', '', sub.name || sub.uid), node('span', '', sub.type === 'remote' ? '远程订阅' : sub.type === 'local' ? '本地订阅' : valueOrDash(sub.type)), node('span', '', `${sub.node_count ?? '未知'} 个节点`), node('span', '', `${safeList(sub.sites).length} 个网站`));
      const tags = node('div', 'tag-row');
      safeList(sub.tags).forEach(tag => append(tags, node('span', 'tag', tag)));
      const stats = append(node('div', 'subscription-details'), detail('剩余', sub.remaining_percent === null || sub.remaining_percent === undefined ? bytes(sub.remaining) : `${bytes(sub.remaining)} · ${quantity(sub.remaining_percent)}%`), detail('已用 / 总量', `${bytes(sub.used)} / ${bytes(sub.total)}`), detail('到期', date(sub.expires_at)), detail('更新', date(sub.updated_at)));
      const warnings = node('div', 'warning-list');
      safeList(sub.warnings).forEach(warning => append(warnings, p(warning, 'warning-text')));
      const providerText = safeList(sub.providers).map(provider => `${provider.name} · ${provider.node_count ?? '?'} 节点 · ${date(provider.updated_at)}`).join('；');
      const providers = providerText ? p(providerText, 'quiet small') : null;
      const actions = append(node('div', 'record-actions'), button('编辑', 'button button-quiet', () => showAliasEditor(row, sub)), button('刷新', 'button button-secondary', event => runAction('refresh', {subscription: sub.uid}, `刷新 ${sub.alias || sub.name}`, event.currentTarget)));
      const sites = safeList(sub.sites).length ? p(`关联网站：${sub.sites.join('、')}`, 'quiet small') : null;
      const more = node('details', 'subscription-more');
      append(more, node('summary', '', '网站与来源'), sites || p('尚未关联网站。', 'quiet small'), providers || p('没有运行来源资料。', 'quiet small'));
      append(row, append(node('div', 'subscription-top'), append(node('div'), heading, meta), actions), tags, stats, warnings, more);
      append(list, row);
    });
  }

  function showAliasEditor(row, sub) {
    const old = $('.alias-editor', row);
    if (old) { old.remove(); return; }
    const form = node('form', 'alias-editor inline-form');
    const aliasLabel = append(node('label', 'field'), node('span', '', '显示名称'));
    const aliasInput = node('input'); aliasInput.name = 'alias'; aliasInput.value = sub.alias || ''; aliasInput.placeholder = sub.name || '订阅名称';
    append(aliasLabel, aliasInput);
    const tagsLabel = append(node('label', 'field'), node('span', '', '标签（逗号分隔）'));
    const tagsInput = node('input'); tagsInput.name = 'tags'; tagsInput.value = safeList(sub.tags).join(', '); tagsInput.placeholder = '工作, 常用';
    append(tagsLabel, tagsInput);
    const save = node('button', 'button button-primary', '保存'); save.type = 'submit';
    append(form, aliasLabel, tagsLabel, save, button('取消', 'button button-quiet', () => form.remove()));
    form.addEventListener('submit', async event => {
      event.preventDefault();
      const result = await runAction('alias', {subscription: sub.uid, alias: aliasInput.value.trim(), tags: tagsInput.value.split(',').map(x => x.trim()).filter(Boolean)}, '保存订阅标记', save);
      if (actionAccepted(result)) { form.remove(); renderOverview(); }
    });
    append(row, form);
    aliasInput.focus();
  }

  function routeSite(route) { return route.site || route.domain || ''; }
  function renderRoutes() {
    const routes = safeList(state.snapshot.routes);
    $('#route-count').textContent = `${routes.length} 条规则`;
    const list = clear($('#route-list'));
    if (!routes.length) { append(list, empty('还没有网站规则', '添加网站后即可在这里停用、恢复或删除。')); return; }
    routes.forEach(route => {
      const site = routeSite(route);
      const row = node('article', 'route-record');
      const main = append(node('div', 'route-main'), node('strong', 'route-domain', site || '未知域名'), node('span', `state-pill ${route.enabled === false ? 'muted' : 'success'}`, route.enabled === false ? '已停用' : '已启用'));
      const meta = p(`${route.exact ? '仅此域名' : '包含子域名'} · ${route.subscription_name || subscriptionName(route.subscription)}`, 'quiet');
      const actions = append(node('div', 'record-actions'), button(route.enabled === false ? '恢复' : '停用', 'button button-quiet', event => runAction('toggle', {site, enabled: route.enabled === false}, `${route.enabled === false ? '恢复' : '停用'} ${site}`, event.currentTarget)), button('删除', 'button button-danger', event => {
        if (confirm(`删除 ${site} 的网站规则？`)) runAction('remove', {site}, `删除 ${site}`, event.currentTarget);
      }));
      append(row, append(node('div'), main, meta), actions);
      append(list, row);
    });
  }

  async function loadNodes() {
    const uid = $('#nodes-subscription').value;
    const target = clear($('#nodes-content'));
    if (!uid) { append(target, empty('请选择订阅', '节点偏好按订阅独立保存。')); return; }
    append(target, p('正在读取节点…', 'quiet'));
    try {
      const result = await api(`/api/nodes?subscription=${encodeURIComponent(uid)}`);
      if ($('#nodes-subscription').value !== uid) return;
      state.nodes = result;
      renderNodes(result);
    } catch (error) { clear(target); append(target, empty('无法读取节点', `${error.message} 请重新选择订阅重试。`)); }
  }

  function renderNodes(data) {
    const target = clear($('#nodes-content'));
    const nodes = safeList(data.nodes);
    const form = node('form', 'stack-form');
    const modeField = append(node('label', 'field'), node('span', '', '选择方式'));
    const mode = node('select'); mode.name = 'mode';
    [['manual', '保持手动选择'], ['auto', '同订阅自动选择可用节点'], ['fallback', '按顺序回退'], ['fixed', '固定节点']].forEach(([value, label]) => {
      const option = node('option', '', label); option.value = value; append(mode, option);
    });
    mode.value = ['manual', 'auto', 'fallback', 'fixed'].includes(data.policy?.mode) ? data.policy.mode : 'manual'; append(modeField, mode);
    const nodeField = append(node('label', 'field'), node('span', '', '固定节点'));
    const nodeSelect = node('select'); nodeSelect.name = 'node';
    append(nodeSelect, (() => { const option = node('option', '', '选择节点'); option.value = ''; return option; })());
    nodes.forEach(item => { const option = node('option', '', `${item.name}${item.delay == null ? '' : ` · ${item.delay} ms`}${item.alive === false ? ' · 不可用' : ''}`); option.value = item.name; append(nodeSelect, option); });
    if (data.policy?.node && !nodes.some(item => item.name === data.policy.node)) { const option = node('option', '', `${data.policy.node} · 当前节点列表未找到`); option.value = data.policy.node; append(nodeSelect, option); }
    nodeSelect.value = data.policy?.node || ''; append(nodeField, nodeSelect);
    const regionsField = append(node('label', 'field'), node('span', '', '地区筛选（逗号分隔，可留空）'));
    const regions = node('input'); regions.name = 'regions'; regions.placeholder = '香港, 日本'; regions.value = safeList(data.policy?.regions).join(', '); append(regionsField, regions);
    const syncFields = () => { nodeField.classList.toggle('hidden', mode.value !== 'fixed'); regionsField.classList.toggle('hidden', mode.value === 'fixed'); };
    mode.addEventListener('change', syncFields); syncFields();
    const save = node('button', 'button button-primary', '保存节点偏好'); save.type = 'submit';
    append(form, modeField, nodeField, regionsField, save);
    form.addEventListener('submit', async event => {
      event.preventDefault();
      const args = {subscription: $('#nodes-subscription').value, mode: mode.value, regions: mode.value === 'fixed' ? [] : regions.value.split(',').map(x => x.trim()).filter(Boolean)};
      if (mode.value === 'fixed') { if (!nodeSelect.value) { nodeSelect.focus(); return; } args.node = nodeSelect.value; }
      const result = await runAction('policy', args, '保存节点偏好', save);
      if (result) loadNodes();
    });
    append(target, node('h2', '', '选择规则'), p(`当前代理组：${valueOrDash(data.group)} · 当前节点：${valueOrDash(data.selected)}`, 'quiet'), form);
    const nodeList = node('div', 'node-list');
    if (!nodes.length) append(nodeList, empty('没有可用节点资料', '请先刷新此订阅，再重新读取节点。'));
    else nodes.forEach(item => append(nodeList, append(node('div', 'node-line'), node('strong', '', item.name), node('span', `state-pill ${item.alive === false ? 'muted' : item.alive === true ? 'success' : 'warning'}`, item.alive === false ? '不可用' : item.alive === true ? '可用' : '状态未知'), node('span', 'quiet', item.delay == null ? '延迟未知' : `${item.delay} ms`))));
    append(target, node('h3', '', `订阅节点（${nodes.length}）`), nodeList);
  }

  function renderScenarios() {
    const target = clear($('#scenario-list'));
    const scenarios = safeList(state.snapshot.scenarios);
    if (!scenarios.length) append(target, empty('还没有保存场景', '保存当前规则后，就能在这里预览和切换。'));
    scenarios.forEach(scene => {
      const row = append(node('article', 'route-record'), append(node('div'), node('strong', '', scene.name), p(`${scene.route_count ?? '未知'} 条规则`, 'quiet')));
      append(row, append(node('div', 'record-actions'), button('预览切换', 'button button-secondary', async event => {
        const trigger = event.currentTarget; trigger.disabled = true;
        try {
          const preview = await api(`/api/scene?name=${encodeURIComponent(scene.name)}`);
          state.scenePreview = scene.name;
          const area = clear($('#scenario-preview')); area.classList.remove('hidden');
          append(area, node('h2', '', `切换到「${scene.name}」`), p('请核对下方变更预览，确认后替换当前网站规则。'));
          addJsonDetails(area, preview, '查看预览详情', true);
          if (preview?.state !== 'error' && preview?.status !== 'error') append(area, button('确认切换', 'button button-primary', buttonEvent => {
            if (state.scenePreview !== scene.name) return;
            runAction('scene-use', {name: scene.name, apply: true}, `切换到 ${scene.name}`, buttonEvent.currentTarget).then(result => { if (actionAccepted(result)) { area.classList.add('hidden'); state.scenePreview = null; } });
          }));
        } catch (error) { setMessage(`无法预览场景：${error.message}`); }
        finally { trigger.disabled = false; }
      }), button('删除', 'button button-danger', event => {
        if (confirm(`删除场景「${scene.name}」？`)) runAction('scene-delete', {name: scene.name}, `删除场景 ${scene.name}`, event.currentTarget);
      })));
      append(target, row);
    });
    const presets = clear($('#preset-list'));
    const available = safeList(state.snapshot.presets);
    if (!available.length) append(presets, p('没有可用预设。', 'quiet'));
    available.forEach(item => append(presets, append(node('div', 'preset-line'), append(node('div'), node('strong', '', item.id), p(item.description || '无说明', 'quiet')), button('添加规则', 'button button-secondary', event => {
      const subscription = $('#preset-subscription').value;
      if (!subscription) { $('#preset-subscription').focus(); setMessage('请先为网站预设选择订阅。'); return; }
      runAction('add', {site: item.id, subscription, exact: false}, `添加 ${item.id} 预设`, event.currentTarget);
    }))));
  }

  function addJsonDetails(parent, value, summary, open = false) {
    const details = node('details', 'result-details'); details.open = open;
    const pre = node('pre', 'result-json'); pre.textContent = JSON.stringify(value ?? {}, null, 2);
    append(details, node('summary', '', summary), pre); append(parent, details);
  }

  async function loadPlan() {
    const target = clear($('#plan-content'));
    $('#history-deploy').disabled = true;
    append(target, p('正在生成计划…', 'quiet'));
    try {
      const plan = await api('/api/plan');
      clear(target);
      append(target, append(node('div', 'plan-summary'), detail('基础配置', plan.base_name), detail('规则总数', plan.rule_count), detail('新增种子', plan.seed_count)));
      const files = safeList(plan.changed_files);
      if (files.length) append(target, p(`涉及文件：${files.join('、')}`, 'quiet'));
      const list = node('div', 'plan-list');
      safeList(plan.summary).forEach(item => append(list, append(node('div', 'plan-line'), node('strong', '', item.site), node('span', '', subscriptionName(item.subscription)), node('span', 'quiet', `${item.rules ?? 0} 条`))));
      append(target, list);
      if (!safeList(plan.summary).length) append(target, p('目前没有待应用的网站规则。', 'quiet'));
      $('#history-deploy').disabled = false;
    } catch (error) { clear(target); append(target, empty('计划读取失败', error.message)); }
  }

  function renderHistory() {
    const backups = clear($('#backup-list'));
    const items = safeList(state.snapshot.backups);
    if (!items.length) append(backups, empty('还没有备份', '首次应用配置后，备份会列在这里。'));
    items.forEach(item => append(backups, append(node('div', 'route-record'), append(node('div'), node('strong', '', item.id), p(`${date(item.created_at)} · ${item.status || '状态未知'}`, 'quiet')), button('回滚到此备份', 'button button-danger', event => {
      if (confirm(`回滚到备份 ${item.id}？这会改变当前配置。`)) runAction('rollback', {id: item.id}, `回滚 ${item.id}`, event.currentTarget);
    }))));
    const adoptions = clear($('#adoption-list'));
    const available = safeList(state.snapshot.adoptions);
    if (!available.length) append(adoptions, empty('没有待接管规则', '旧手工配置没有发现可接管的项目。'));
    available.forEach(item => append(adoptions, append(node('div', 'route-record'), append(node('div'), node('strong', '', item.group || item.id), p(`${item.rule_count ?? 0} 条规则 · ${item.subscription_name || subscriptionName(item.subscription)}`, 'quiet'), p(safeList(item.sites).join('、'), 'small')), button('预览接管', 'button button-secondary', async event => {
      const trigger = event.currentTarget; trigger.disabled = true;
      try {
        const preview = await api('/api/action', {method: 'POST', body: {action: 'adopt', args: {id: item.id, commit: false}}});
        state.adoptionPreview = item.id;
        const area = clear($('#adoption-preview'));
        append(area, node('h3', '', `接管预览：${item.group || item.id}`), p('确认后这些旧规则会由本工具管理。'));
        addJsonDetails(area, preview, '查看接管详情', true);
        if (preview?.state !== 'error' && preview?.status !== 'error') append(area, button('确认接管', 'button button-primary', buttonEvent => {
          if (state.adoptionPreview !== item.id) return;
          if (confirm(`确认接管 ${item.group || item.id} 的旧规则？`)) runAction('adopt', {id: item.id, commit: true}, '接管旧规则', buttonEvent.currentTarget).then(result => { if (actionAccepted(result)) { clear(area); state.adoptionPreview = null; } });
        }));
      } catch (error) { setMessage(`无法预览接管：${error.message}`); }
      finally { trigger.disabled = false; }
    }))));
    const integration = clear($('#integration-content'));
    const info = state.snapshot.integration || {};
    append(integration, node('span', `state-pill ${info.available ? 'success' : 'warning'}`, info.available ? '可用' : '需要检查'), p(info.message || '没有集成状态说明。'));
  }

  function renderAlerts() {
    const settings = state.snapshot.alert_settings || {};
    const form = $('#alerts-form');
    if (form.dataset.editing !== 'true') ['expiry_days', 'remaining_percent', 'stale_days'].forEach(key => { form.elements[key].value = settings[key] ?? ''; });
    const target = clear($('#alert-list'));
    const alerts = safeList(state.snapshot.alerts);
    if (!alerts.length) append(target, empty('目前没有提醒', '订阅达到设置的阈值时会出现在这里。'));
    alerts.forEach(item => append(target, append(node('div', 'alert-record'), node('span', `state-pill ${item.level === 'error' ? 'danger' : 'warning'}`, item.level || '提醒'), append(node('div'), node('strong', '', subscriptionName(item.subscription)), p(item.message)))));
    const permission = window.Notification?.permission;
    $('#notification-state').textContent = !('Notification' in window) ? '此浏览器不支持桌面通知' : permission === 'granted' ? '浏览器通知已允许' : permission === 'denied' ? '浏览器通知已被阻止，可在浏览器设置中修改' : '尚未授权浏览器通知';
    $('#browser-notify').disabled = !('Notification' in window) || permission === 'granted' || permission === 'denied';
  }

  function renderDiagnosis(data) {
    const target = clear($('#diagnose-result'));
    append(target, node('h2', '', `诊断：${data.domain || '未知网站'}`));
    const columns = node('div', 'diagnose-grid');
    const planned = append(node('div', 'panel diagnosis'), node('h3', '', '已保存的预期'));
    if (data.planned) append(planned, detail('订阅', subscriptionName(data.planned.subscription)), detail('代理组', data.planned.group), detail('规则状态', data.planned.enabled === false ? '已停用' : '已启用'));
    else append(planned, p('没有匹配的网站规则。', 'quiet'));
    const runtime = append(node('div', 'panel diagnosis'), node('h3', '', '客户端实际规则'));
    if (data.runtime) append(runtime, detail('命中规则', data.runtime.rule), detail('代理组', data.runtime.group), detail('确定性', data.runtime.certain === true ? '确定' : data.runtime.certain === false ? '不确定' : '未知'), p(data.runtime.message || '', 'quiet'));
    else append(runtime, p('尚未读取到客户端匹配结果。', 'quiet'));
    append(columns, planned, runtime); append(target, columns);
    const observed = append(node('div', 'panel'), node('h3', '', '观测链路'));
    if (!safeList(data.observed).length) append(observed, p('没有观测结果。', 'quiet'));
    safeList(data.observed).forEach(item => append(observed, append(node('div', 'plan-line'), node('strong', '', item.rule || '规则未知'), node('span', '', item.chain || '链路未知'), node('span', 'quiet', item.node || '节点未知'))));
    append(target, observed);
    safeList(data.warnings).forEach(warning => append(target, p(warning, 'warning-text')));
  }

  function externalNames(documentValue) {
    const names = new Set();
    const add = value => { if (typeof value === 'string' && value) names.add(value); };
    const readMapping = mapping => {
      if (!mapping || typeof mapping !== 'object') return;
      add(mapping.base_profile);
      safeList(mapping.routes).forEach(item => add(item?.subscription));
      Object.keys(mapping.policies || {}).forEach(add);
    };
    readMapping(documentValue?.mapping);
    Object.values(documentValue?.scenarios || {}).forEach(readMapping);
    return [...names];
  }

  function importBindings() {
    const bindings = {};
    $$('.binding-select', $('#import-bindings')).forEach(select => { if (select.value) bindings[select.dataset.externalName] = select.value; });
    return bindings;
  }

  function renderImportBindings(names) {
    const selected = importBindings();
    const target = clear($('#import-bindings'));
    if (!names.length) return;
    append(target, node('h3', '', '订阅绑定'));
    names.forEach(name => {
      const label = append(node('label', 'field binding-row'), node('span', '', name));
      const select = node('select', 'binding-select'); select.dataset.externalName = name;
      const placeholder = node('option', '', '选择本机订阅'); placeholder.value = ''; append(select, placeholder);
      safeList(state.snapshot.subscriptions).forEach(sub => {
        const option = node('option', '', sub.alias || sub.name || sub.uid); option.value = sub.uid; append(select, option);
      });
      const match = safeList(state.snapshot.subscriptions).find(sub => sub.name === name || sub.alias === name);
      if (selected[name]) select.value = selected[name];
      else if (match) select.value = match.uid;
      select.addEventListener('change', () => { $('#import-commit').classList.add('hidden'); state.importPreview = null; });
      append(label, select); append(target, label);
    });
  }

  function wire() {
    ['input', 'change'].forEach(type => document.addEventListener(type, event => {
      const form = event.target.closest?.('form');
      if (form) form.dataset.editing = 'true';
    }));
    $$('.nav-item').forEach(item => item.addEventListener('click', () => showView(item.dataset.view)));
    $('#reload-button').addEventListener('click', event => { const trigger = event.currentTarget; trigger.disabled = true; loadSnapshot().catch(() => {}).finally(() => { trigger.disabled = false; }); });
    $('#activity-close').addEventListener('click', () => $('#activity').classList.add('hidden'));
    $('#subscription-search').addEventListener('input', renderOverview);
    $('#refresh-all').addEventListener('click', event => runAction('refresh', {subscription: 'all'}, '刷新全部订阅', event.currentTarget));
    $('#add-route-form').addEventListener('submit', async event => {
      event.preventDefault(); const form = event.currentTarget;
      const result = await runAction('add', {site: form.elements.site.value.trim(), subscription: form.elements.subscription.value, exact: form.elements.exact.checked}, '添加网站规则', $('button[type="submit"]', form));
      if (actionAccepted(result)) form.elements.site.value = '';
    });
    $('#batch-route-form').addEventListener('submit', async event => {
      event.preventDefault(); const form = event.currentTarget;
      const sites = form.elements.sites.value.split(/\r?\n/).map(x => x.trim()).filter(Boolean);
      if (!sites.length) { form.elements.sites.focus(); return; }
      const result = await runAction('batch', {sites, subscription: form.elements.subscription.value, exact: form.elements.exact.checked}, '批量添加网站', $('button[type="submit"]', form));
      if (actionAccepted(result)) form.elements.sites.value = '';
    });
    $('#deploy-button').addEventListener('click', () => { showView('history'); $('#plan-content').scrollIntoView({block: 'start'}); });
    $('#history-deploy').addEventListener('click', event => runAction('deploy', {}, '应用配置', event.currentTarget).then(loadPlan));
    $('#verify-button').addEventListener('click', event => runAction('verify', {}, '检查已生效状态', event.currentTarget));
    $('#plan-button').addEventListener('click', loadPlan);
    $('#nodes-subscription').addEventListener('change', loadNodes);
    $('#scene-save-form').addEventListener('submit', async event => {
      event.preventDefault(); const form = event.currentTarget;
      const name = form.elements.name.value.trim(); if (!name) return;
      const result = await runAction('scene-save', {name}, `保存场景 ${name}`, $('button[type="submit"]', form));
      if (actionAccepted(result)) form.reset();
    });
    $('#diagnose-form').addEventListener('submit', async event => {
      event.preventDefault(); const form = event.currentTarget; const trigger = $('button[type="submit"]', form);
      trigger.disabled = true;
      try { const result = await api(`/api/diagnose?domain=${encodeURIComponent(form.elements.domain.value.trim())}`); renderDiagnosis(result); hideMessage(); }
      catch (error) { setMessage(`诊断失败：${error.message}`); }
      finally { trigger.disabled = false; }
    });
    $('#export-button').addEventListener('click', async event => {
      const trigger = event.currentTarget; trigger.disabled = true;
      try {
        const data = await api('/api/export');
        const blob = new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'});
        const href = URL.createObjectURL(blob); const link = node('a'); link.href = href; link.download = `verge-routes-${new Date().toISOString().slice(0, 10)}.json`; document.body.append(link); link.click(); link.remove();
        setTimeout(() => URL.revokeObjectURL(href), 1000); hideMessage();
      } catch (error) { setMessage(`导出失败：${error.message}`); }
      finally { trigger.disabled = false; }
    });
    $('#import-file').addEventListener('change', async event => {
      state.importDocument = null; state.importPreview = null; $('#import-preview').disabled = true; $('#import-commit').classList.add('hidden'); clear($('#import-result')); clear($('#import-bindings'));
      const file = event.currentTarget.files?.[0]; if (!file) return;
      try { state.importDocument = JSON.parse(await file.text()); state.importNames = externalNames(state.importDocument); renderImportBindings(state.importNames); $('#import-preview').disabled = false; append($('#import-result'), p(`已读取 ${file.name}。请核对订阅绑定后预览。`, 'quiet')); hideMessage(); }
      catch { setMessage('文件不是有效 JSON。请检查文件后重新选择。'); }
    });
    $('#import-preview').addEventListener('click', async event => {
      if (!state.importDocument) return; const trigger = event.currentTarget; trigger.disabled = true;
      try {
        const result = await api('/api/action', {method: 'POST', body: {action: 'import', args: {document: state.importDocument, bindings: importBindings(), commit: false}}});
        const missing = safeList(result.missing).filter(name => typeof name === 'string');
        if (missing.some(name => !state.importNames.includes(name))) {
          state.importNames = [...new Set([...state.importNames, ...missing])];
          renderImportBindings(state.importNames);
        }
        state.importPreview = result; const target = clear($('#import-result'));
        append(target, node('h3', '', '导入预览'), p(result.ready ? '绑定完整，可确认导入。' : '仍有缺少绑定或不支持的条目，请调整后重新预览。', result.ready ? 'success-text' : 'warning-text'));
        addJsonDetails(target, result, '查看路线与缺失项', true);
        $('#import-commit').classList.toggle('hidden', !result.ready);
        hideMessage();
      } catch (error) { setMessage(`导入预览失败：${error.message}`); $('#import-commit').classList.add('hidden'); }
      finally { trigger.disabled = false; }
    });
    $('#import-commit').addEventListener('click', async event => {
      if (!state.importDocument || !state.importPreview?.ready) return;
      const result = await runAction('import', {document: state.importDocument, bindings: importBindings(), commit: true}, '导入映射', event.currentTarget);
      if (actionAccepted(result)) { $('#import-commit').classList.add('hidden'); state.importPreview = null; }
    });
    $('#alerts-form').addEventListener('submit', event => {
      event.preventDefault(); const form = event.currentTarget;
      runAction('alerts-config', {expiry_days: Number(form.elements.expiry_days.value), remaining_percent: Number(form.elements.remaining_percent.value), stale_days: Number(form.elements.stale_days.value)}, '保存提醒阈值', $('button[type="submit"]', form));
    });
    $('#notify-button').addEventListener('click', event => runAction('notify', {}, '发送提醒', event.currentTarget));
    $('#browser-notify').addEventListener('click', async () => {
      if (!('Notification' in window)) return;
      try { await Notification.requestPermission(); renderAlerts(); }
      catch (error) { setMessage(`浏览器通知授权失败：${error.message}`); }
    });
  }

  captureToken();
  wire();
  loadSnapshot().catch(() => {});
  setInterval(() => {
    if (state.busy) return;
    loadSnapshot({silent: true, preserveEdits: true}).catch(() => {});
  }, 25000);
})();
