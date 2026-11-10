"""End-to-end checks for the SmartRent BD design prototype (Playwright, headless Chromium).

Run: python3 prototype/test_prototype.py
Covers every view for every role in both languages at phone and desktop width, plus the
money rules (no overpayment, transaction-ID duplicates, invoice maths), organization
isolation, manager property scope and permissions, and expired-plan read-only mode.
"""
import os, sys
from playwright.sync_api import sync_playwright

D = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.environ.get('SHOTS')
src = open(os.path.join(D, 'index.html'), encoding='utf-8').read()
html = ('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<style>:root{padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}body{margin:0}[hidden]{display:none!important}</style></head><body>'
        + src + '</body></html>')
tmp = os.path.join(D, '_wrapped.html')
open(tmp, 'w', encoding='utf-8').write(html)
URL = 'file://' + tmp
KEY = 'smartrent-bd-prototype-v1'
fails, passed = [], [0]

def check(c, m):
    if c: passed[0] += 1
    else: fails.append(m); print('FAIL', m)

def state(pg):
    return pg.evaluate(f'JSON.parse(localStorage.getItem("{KEY}")).S')

VIEWS = {'landlord': ['dash', 'props', 'tenants', 'tickets', 'notices', 'billing', 'daily', 'expenses', 'analytics', 'sub', 'team'],
         'manager': ['dash', 'billing', 'daily', 'tenants', 'tickets', 'notices'],
         'super': ['overview', 'orgs', 'plans', 'subs', 'audit', 'settings'],
         'tenant': ['tdash', 'tbills', 'ttickets', 'tnotices']}

with sync_playwright() as p:
    b = p.chromium.launch()
    for w in (1366, 390):
        ctx = b.new_context(viewport={'width': w, 'height': 900})
        ctx.route('https://fonts.googleapis.com/**', lambda r: r.abort())
        pg = ctx.new_page(); errs = []
        pg.on('pageerror', lambda e: errs.append(str(e)))
        pg.goto(URL); pg.wait_for_timeout(300)
        for lang in ('bn', 'en'):
            pg.click('#lang-' + lang)
            for role, views in VIEWS.items():
                pg.select_option('#roleSel', role)
                for v in views:
                    pg.evaluate(f'location.hash="{v}"'); pg.wait_for_timeout(50)
                    ov = pg.evaluate('document.documentElement.scrollWidth - innerWidth')
                    check(ov <= 0, f'{w} {lang} {role}/{v} horizontal overflow {ov}px')
                    txt = pg.inner_text('#view')
                    check('undefined' not in txt and 'NaN' not in txt and 'null' not in txt, f'{w} {lang} {role}/{v} shows undefined/NaN/null')
                    check(len(txt) > 40, f'{w} {lang} {role}/{v} rendered content')
        check(not errs, f'{w} page errors: {errs[:3]}')
        check(('EFT' + 'NIX') not in pg.content().upper(), 'no previous brand name anywhere')

        if w == 1366:
            pg.click('#lang-bn'); pg.click('#lang-bn')
            pg.select_option('#roleSel', 'landlord'); pg.evaluate('location.hash="dash"'); pg.wait_for_timeout(50)
            pg.click('button[data-act="reset"]'); pg.wait_for_timeout(80)
            S = state(pg)
            bad = sum(1 for x in S['bills'] if sum(i[1] for i in x['items']) != x['total'])
            over = sum(1 for x in S['bills'] if sum(q['amount'] for q in S['payments'] if q['billId'] == x['id']) > x['total'])
            tid = {t['id']: t for t in S['tenants']}
            leak = any(tid[x['tenantId']]['orgId'] != x['orgId'] for x in S['bills'])
            dupe = len({(x['tenantId'], x['month']) for x in S['bills']}) != len(S['bills'])
            check(bad == 0 and over == 0 and not leak and not dupe, f'seed invariants bad={bad} over={over} leak={leak} dupe={dupe}')
            print('seed', len(S['orgs']), 'orgs', len(S['units']), 'units', len(S['tenants']), 'tenants', len(S['bills']), 'invoices')

            # payment rules
            pg.evaluate('location.hash="billing"'); pg.wait_for_timeout(80)
            pg.click('button[data-act="pay"]')
            pg.fill('#pAmt', '99999999'); pg.click('button[data-act="savePay"]'); check(pg.is_visible('#ferr'), 'overpayment blocked')
            pg.fill('#pAmt', '500'); pg.select_option('#pMethod', 'bkash'); pg.fill('#pTxn', ''); pg.click('button[data-act="savePay"]')
            check('ট্রানজ্যাকশন' in pg.inner_text('#ferr'), 'bKash needs transaction ID')
            used = S['payments'][[q['txn'] for q in S['payments']].index(next(q['txn'] for q in S['payments'] if q['txn']))]['txn']
            pg.fill('#pTxn', used); pg.click('button[data-act="savePay"]'); check('আগেই' in pg.inner_text('#ferr'), 'duplicate transaction ID blocked')
            pg.fill('#pTxn', 'TESTTX12345'); pg.click('button[data-act="savePay"]'); pg.wait_for_timeout(100)
            check(pg.is_visible('#rcpt') and 'R-' in pg.inner_text('#rcpt') and 'SmartRent BD' in pg.inner_text('#rcpt'), 'receipt after payment')
            pg.click('button[data-act="close"]')
            S2 = state(pg)
            check(len(S2['payments']) == len(S['payments']) + 1, 'exactly one payment added')

            # add tenant with validation, then generate invoice with meter reading
            pg.evaluate('location.hash="tenants"'); pg.wait_for_timeout(80)
            pg.click('button[data-act="newTenant"]'); pg.fill('#tName', 'Test Tenant'); pg.fill('#tPhone', '12345')
            opts = pg.evaluate('[...document.querySelectorAll("#tUnit option")].map(o=>o.value).filter(Boolean)')
            check(len(opts) > 0, 'vacant unit offered')
            pg.select_option('#tUnit', opts[0]); pg.click('button[data-act="saveTenant"]'); check(pg.is_visible('#ferr'), 'bad phone rejected')
            pg.fill('#tPhone', '01711111111'); pg.click('button[data-act="saveTenant"]'); pg.wait_for_timeout(80)
            check(any(t['name'] == 'Test Tenant' for t in state(pg)['tenants']), 'tenant saved')
            pg.evaluate('location.hash="billing"'); pg.wait_for_timeout(80)
            inp = pg.query_selector('input[data-read]'); check(inp is not None, 'meter input for new tenant')
            mn = int(inp.get_attribute('min'))
            inp.fill(str(mn - 5)); pg.click('button[data-act="gen"]'); pg.wait_for_timeout(60)
            S3 = state(pg); t3 = next(t for t in S3['tenants'] if t['name'] == 'Test Tenant')
            check(not any(x['tenantId'] == t3['id'] for x in S3['bills']), 'lower meter reading refused')
            pg.fill('input[data-read]', str(mn + 120)); pg.click('button[data-act="gen"]'); pg.wait_for_timeout(100)
            S4 = state(pg); bl = [x for x in S4['bills'] if x['tenantId'] == t3['id']]; u = next(x for x in S4['units'] if x['id'] == t3['unitId'])
            check(len(bl) == 1 and bl[0]['cur'] - bl[0]['prev'] == 120 and dict(bl[0]['items'])['elec'] == round(120 * u['elecRate']) and bl[0]['total'] == sum(i[1] for i in bl[0]['items']), 'invoice electricity maths')
            check(pg.query_selector('button[data-act="gen"]') is None, 'no second invoice offered for same month')

            # expenses feed net income
            pg.evaluate('location.hash="expenses"'); pg.wait_for_timeout(60)
            pg.click('button[data-act="newExpense"]'); pg.fill('#exAmt', '1234'); pg.click('button[data-act="saveExpense"]'); pg.wait_for_timeout(80)
            check(any(e['amount'] == 1234 for e in state(pg)['expenses']), 'expense saved')

            # maintenance workflow: cannot reach "assigned" without assignee
            pg.evaluate('location.hash="tickets"'); pg.wait_for_timeout(60)
            S5 = state(pg); k = next(x for x in S5['tickets'] if x['status'] == 'submitted')
            pg.click(f'button[data-act="ticket"][data-id="{k["id"]}"]'); pg.click('button[data-act="advTicket"]'); pg.wait_for_timeout(60)
            check(next(x for x in state(pg)['tickets'] if x['id'] == k['id'])['status'] == 'reviewed', 'ticket submitted -> reviewed')
            pg.click(f'button[data-act="ticket"][data-id="{k["id"]}"]'); pg.select_option('#kAs', ''); pg.click('button[data-act="advTicket"]')
            check(pg.is_visible('#ferr'), 'assign step needs a person')
            pg.click('button[data-act="close"]')

            # manager scope and permissions
            pg.select_option('#roleSel', 'manager'); pg.select_option('#mgrSel', 'm2'); pg.evaluate('location.hash="tenants"'); pg.wait_for_timeout(80)
            S6 = state(pg); m2 = next(x for x in S6['users'] if x['id'] == 'm2')
            units_m2 = {x['id'] for x in S6['units'] if x['propId'] in m2['props']}
            expect = len([t for t in S6['tenants'] if t['active'] and t['unitId'] in units_m2])
            rows = pg.evaluate('document.querySelectorAll("#view tbody tr").length')
            check(rows == min(expect, 12), f'manager sees only assigned properties {rows} vs {expect}')
            check(pg.is_disabled('button[data-act="newTenant"]'), 'manager without tenant permission cannot add')
            check(pg.query_selector('button[data-act="nid"]') is None, 'manager without NID permission cannot reveal')

            # expired organization is read-only but data visible
            pg.select_option('#roleSel', 'landlord'); pg.select_option('#orgSel', 'o6'); pg.evaluate('location.hash="tenants"'); pg.wait_for_timeout(80)
            check(pg.is_disabled('button[data-act="newTenant"]'), 'expired org read-only')
            check(pg.evaluate('document.querySelectorAll("#view tbody tr").length') > 0, 'expired org data still visible')

            # isolation: o2 landlord sees only o2 tenants
            pg.select_option('#orgSel', 'o2'); pg.wait_for_timeout(60)
            S7 = state(pg); n2 = len([t for t in S7['tenants'] if t['orgId'] == 'o2' and t['active']])
            check(pg.evaluate('document.querySelectorAll("#view tbody tr").length') == min(n2, 12), 'organization isolation')

            # super admin: verified payment reactivates, duplicate ref refused
            pg.select_option('#roleSel', 'super'); pg.evaluate('location.hash="subs"'); pg.wait_for_timeout(60)
            pg.click('button[data-act="verifySub"]'); pg.fill('#vTxn', 'BKTEST999'); pg.click('button[data-act="saveVerify"]'); pg.wait_for_timeout(60)
            S8 = state(pg); check(sum(1 for s in S8['subPays'] if s['ref'] == 'BKTEST999') == 1, 'verified subscription payment recorded')
            check(sum(1 for o in S8['orgs'] if o['status'] in ('grace', 'expired')) == 1, 'one org reactivated')
            # tenant sees only own invoices; online pay is disabled (never simulated)
            pg.select_option('#roleSel', 'tenant'); pg.evaluate('location.hash="tdash"'); pg.wait_for_timeout(60)
            check(pg.is_disabled('#view button.primary[disabled]'), 'online payment not simulated')
            pg.evaluate('location.hash="tbills"'); pg.wait_for_timeout(60)
            tsel = pg.eval_on_selector('#tenSel', 'e=>e.value'); S9 = state(pg)
            check(pg.evaluate('document.querySelectorAll("#view tbody tr").length') == len([x for x in S9['bills'] if x['tenantId'] == tsel]), 'tenant sees only own invoices')
            pg.select_option('#roleSel', 'landlord'); pg.select_option('#orgSel', 'o1'); pg.evaluate('location.hash="dash"'); pg.wait_for_timeout(60)
            pg.click('button[data-act="reset"]')

        if SHOTS:
            for name, role, view in (('dash', 'landlord', 'dash'), ('billing', 'landlord', 'billing'), ('analytics', 'landlord', 'analytics'), ('super', 'super', 'overview'), ('plans', 'super', 'plans'), ('tenant', 'tenant', 'tdash'), ('tickets', 'landlord', 'tickets')):
                pg.click('#lang-bn'); pg.select_option('#roleSel', role)
                if role == 'landlord': pg.select_option('#orgSel', 'o1')
                pg.evaluate(f'location.hash="{view}"'); pg.wait_for_timeout(150)
                pg.screenshot(path=os.path.join(SHOTS, f'{w}_{name}.png'), full_page=(w == 390 and name == 'dash'))
        ctx.close()
    b.close()
os.remove(tmp)
print(f'{passed[0]} passed, {len(fails)} failed')
sys.exit(1 if fails else 0)
