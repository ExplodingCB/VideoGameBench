"""Test shop actions: buy, reroll, sell."""
import socket, json, time, re

def send(s, msg): s.sendall((json.dumps(msg) + '\n').encode())
def drain(s):
    try:
        s.settimeout(2)
        while True:
            d = s.recv(8192)
            if not d: break
    except: pass
def poll_state(s):
    for attempt in range(15):
        send(s, {'method': 'gamestate'})
        time.sleep(1.5)
        buf = ''
        s.settimeout(5)
        while True:
            try:
                chunk = s.recv(8192).decode()
                if not chunk: break
                buf += chunk
                if '===END===' in buf: break
            except: break
        if 'BALATRO BENCH' in buf and 'ACTIONS' in buf:
            parts = buf.split('===END===')
            for p in reversed(parts):
                if 'BALATRO BENCH' in p and 'ACTIONS' in p:
                    return p.strip()
    return None
def do_act(s, action, wait=8):
    send(s, action)
    time.sleep(wait)
    drain(s)

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(('127.0.0.1', 12345))
time.sleep(0.5)
drain(s)

# Start run
send(s, {'method': 'start', 'deck': 'Red Deck', 'stake': 1})
time.sleep(5); drain(s)

# Select blind
do_act(s, {'action': 'select'})

# Play hands until we win or lose
for i in range(5):
    state = poll_state(s)
    if not state or 'YOUR HAND' not in state:
        break
    do_act(s, {'action': 'play', 'cards': [1,2,3,4,5]})

# Cash out
state = poll_state(s)
if state and 'Cash Out' in state:
    print('Cashing out...')
    do_act(s, {'action': 'cash_out'}, wait=10)

# Shop
state = poll_state(s)
if not state or 'Shop' not in state:
    print(f'Not in shop. State phase: {state[:100] if state else "none"}')
    s.close()
    exit()

print('=== SHOP STATE ===')
for line in state.split('\n'):
    l = line.strip()
    if l and ('Money' in l or l.startswith('[') or 'FOR SALE' in l or 'BOOSTER' in l or 'VOUCHER' in l or 'Reroll' in l or 'JOKER' in l or 'CONSUMABLE' in l):
        print(f'  {l}')

# Test BUY card 1
print('\n>>> BUY card 1')
do_act(s, {'action': 'buy', 'type': 'card', 'index': 1}, wait=5)
state = poll_state(s)
if state:
    print('After buy:')
    for line in state.split('\n'):
        l = line.strip()
        if 'Money' in l or 'YOUR JOKER' in l or 'YOUR CONSUMABLE' in l or (l.startswith('[') and ('sell' in l or 'Joker' in l)):
            print(f'  {l}')

# Test REROLL
money_m = re.search(r'Money:\s*\$(\d+)', state) if state else None
money = int(money_m.group(1)) if money_m else 0
if money >= 5:
    print(f'\n>>> REROLL (have ${money})')
    do_act(s, {'action': 'reroll'}, wait=5)
    state = poll_state(s)
    if state:
        print('After reroll:')
        for line in state.split('\n'):
            l = line.strip()
            if 'Money' in l or 'FOR SALE' in l or (l.startswith('[') and 'Joker' in l):
                print(f'  {l}')

# Test NEXT ROUND
print('\n>>> NEXT_ROUND')
do_act(s, {'action': 'next_round'}, wait=8)
state = poll_state(s)
if state:
    phase = [l.strip() for l in state.split('\n') if 'Phase' in l or 'Blind' in l]
    print(f'After next_round: {phase[0] if phase else "unknown"}')

s.close()
print('\n=== SHOP TEST COMPLETE ===')
