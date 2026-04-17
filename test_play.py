"""Me (Claude) playing Balatro to test every action works."""
import socket, json, time, re
from collections import Counter

def send(s, msg):
    s.sendall((json.dumps(msg) + '\n').encode())

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

def do_action(s, action, wait=8):
    print(f'  >>> {json.dumps(action)}')
    send(s, action)
    time.sleep(wait)
    drain(s)

def parse_cards(state):
    cards = []
    for line in state.split('\n'):
        m = re.match(r'\s*\[(\d+)\]\s+(\w+)\s+of\s+(\w+)\s+\|\s+Chips:\s+(\d+)', line)
        if m:
            cards.append({
                'idx': int(m.group(1)),
                'rank': m.group(2),
                'suit': m.group(3),
                'chips': int(m.group(4)),
            })
    return cards

RANK_ORDER = {'2':2,'3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,'10':10,'Jack':11,'Queen':12,'King':13,'Ace':14}

def find_straight(cards):
    """Find best straight in hand, returns indices or None."""
    rank_vals = sorted(set(RANK_ORDER.get(c['rank'], 0) for c in cards), reverse=True)
    # Check from highest down for best straight
    for i in range(len(rank_vals) - 4):
        window = rank_vals[i:i+5]
        if window[0] - window[4] == 4:
            target_vals = set(range(window[4], window[4]+5))
            indices = []
            used_vals = set()
            for c in cards:
                v = RANK_ORDER.get(c['rank'], 0)
                if v in target_vals and v not in used_vals:
                    indices.append(c['idx'])
                    used_vals.add(v)
            if len(indices) == 5:
                return indices
    # Ace-low straight: A,2,3,4,5
    vals = set(RANK_ORDER.get(c['rank'], 0) for c in cards)
    if {14, 2, 3, 4, 5}.issubset(vals):
        target = {14, 2, 3, 4, 5}
        indices = []
        used = set()
        for c in cards:
            v = RANK_ORDER.get(c['rank'], 0)
            if v in target and v not in used:
                indices.append(c['idx'])
                used.add(v)
        if len(indices) == 5:
            return indices
    return None

def find_flush(cards):
    """Find best flush in hand, returns indices or None."""
    suits = Counter(c['suit'] for c in cards)
    for suit, cnt in suits.most_common():
        if cnt >= 5:
            flush_cards = sorted(
                [c for c in cards if c['suit'] == suit],
                key=lambda c: c['chips'], reverse=True
            )[:5]
            return [c['idx'] for c in flush_cards]
    return None

def find_best_play(cards):
    ranks = Counter(c['rank'] for c in cards)
    suits = Counter(c['suit'] for c in cards)

    # Check everything, then pick the best
    # Straight flush (flush + straight with same cards)
    flush_suit = None
    for suit, cnt in suits.most_common():
        if cnt >= 5:
            flush_suit = suit
            break
    if flush_suit:
        flush_cards = [c for c in cards if c['suit'] == flush_suit]
        sf = find_straight(flush_cards)
        if sf:
            return sf, 'Straight Flush'

    # Four of a kind
    quads = [r for r, cnt in ranks.items() if cnt >= 4]
    if quads:
        indices = [c['idx'] for c in cards if c['rank'] == quads[0]][:4]
        return indices, 'Four of a Kind'

    # Full house
    trips = [r for r, cnt in ranks.items() if cnt >= 3]
    if trips:
        trip_rank = max(trips, key=lambda r: RANK_ORDER.get(r, 0))
        trip_cards = [c['idx'] for c in cards if c['rank'] == trip_rank][:3]
        other_pairs = [r for r, cnt in ranks.items() if cnt >= 2 and r != trip_rank]
        if other_pairs:
            pair_rank = max(other_pairs, key=lambda r: RANK_ORDER.get(r, 0))
            pair_cards = [c['idx'] for c in cards if c['rank'] == pair_rank][:2]
            return trip_cards + pair_cards, 'Full House'

    # Flush
    flush = find_flush(cards)
    if flush:
        return flush, 'Flush'

    # Straight
    straight = find_straight(cards)
    if straight:
        return straight, 'Straight'

    # Three of a kind
    if trips:
        trip_rank = max(trips, key=lambda r: RANK_ORDER.get(r, 0))
        indices = [c['idx'] for c in cards if c['rank'] == trip_rank][:3]
        return indices, 'Three of a Kind'

    # Two pair
    pairs = [r for r, cnt in ranks.items() if cnt >= 2]
    if len(pairs) >= 2:
        pair_ranks = sorted(pairs, key=lambda r: RANK_ORDER.get(r, 0), reverse=True)[:2]
        indices = []
        for r in pair_ranks:
            indices.extend([c['idx'] for c in cards if c['rank'] == r][:2])
        return indices, 'Two Pair'

    # Pair
    if len(pairs) == 1:
        indices = [c['idx'] for c in cards if c['rank'] == pairs[0]][:2]
        return indices, 'Pair'

    # High card - play highest single
    best = max(cards, key=lambda c: c['chips'])
    return [best['idx']], 'High Card'

def find_discard(cards):
    ranks = Counter(c['rank'] for c in cards)
    paired_ranks = {r for r, cnt in ranks.items() if cnt >= 2}

    if paired_ranks:
        to_discard = [c for c in cards if c['rank'] not in paired_ranks]
        to_discard.sort(key=lambda c: c['chips'])
        return [c['idx'] for c in to_discard[:min(5, len(to_discard))]], 'Discard non-pairs'

    sorted_cards = sorted(cards, key=lambda c: c['chips'])
    return [c['idx'] for c in sorted_cards[:5]], 'Discard lowest 5'


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(('127.0.0.1', 12345))
    time.sleep(0.5)
    drain(s)

    print('=== Starting fresh run ===')
    send(s, {'method': 'start', 'deck': 'Red Deck', 'stake': 1})
    time.sleep(5)
    drain(s)

    used_discard_this_round = False

    for turn in range(50):
        state = poll_state(s)
        if not state:
            print(f'Turn {turn}: NO STATE - stopping')
            break

        if 'Blind Select' in state:
            print(f'\nTurn {turn}: BLIND SELECT')
            do_action(s, {'action': 'select'})
            used_discard_this_round = False

        elif 'YOUR HAND' in state and 'Round:' in state:
            cards = parse_cards(state)
            score_m = re.search(r'Current Score:\s*([\d,]+)', state)
            target_m = re.search(r'Target Score:\s*([\d,]+)', state)
            hands_m = re.search(r'Hands Remaining:\s*(\d+)', state)
            discards_m = re.search(r'Discards Remaining:\s*(\d+)', state)
            score = int(score_m.group(1).replace(',', '')) if score_m else 0
            target = int(target_m.group(1).replace(',', '')) if target_m else 300
            hands = int(hands_m.group(1)) if hands_m else 0
            discards = int(discards_m.group(1)) if discards_m else 0

            card_str = ', '.join(f"{c['rank'][:2]}{c['suit'][0]}" for c in cards)
            print(f'\nTurn {turn}: HAND [{card_str}] Score:{score}/{target} H:{hands} D:{discards}')

            play_indices, play_name = find_best_play(cards)

            # If only high card and we have discards, discard first
            if play_name == 'High Card' and discards > 0 and not used_discard_this_round:
                disc_indices, disc_reason = find_discard(cards)
                print(f'  {disc_reason}: cards {disc_indices}')
                do_action(s, {'action': 'discard', 'cards': disc_indices})
                used_discard_this_round = True
            else:
                print(f'  Playing {play_name}: cards {play_indices}')
                do_action(s, {'action': 'play', 'cards': play_indices})

        elif 'Cash Out' in state:
            print(f'\nTurn {turn}: CASH OUT')
            do_action(s, {'action': 'cash_out'}, wait=10)

        elif 'Shop' in state:
            # Extract money
            money_m = re.search(r'Money:\s*\$(\d+)', state)
            money = int(money_m.group(1)) if money_m else 0

            shop_lines = []
            in_sale = False
            for line in state.split('\n'):
                l = line.strip()
                if 'FOR SALE' in l:
                    in_sale = True
                elif l.startswith('---') and in_sale:
                    in_sale = False
                elif in_sale and l.startswith('['):
                    shop_lines.append(l)

            print(f'\nTurn {turn}: SHOP (${money})')
            for item in shop_lines:
                print(f'  {item}')

            print('  Leaving shop...')
            do_action(s, {'action': 'next_round'}, wait=8)

        elif 'Game Over' in state:
            print(f'\nTurn {turn}: GAME OVER')
            for line in state.split('\n'):
                l = line.strip()
                if l and ('Result' in l or 'Ante' in l or 'Rounds' in l or 'Score' in l):
                    print(f'  {l}')
            break

        elif 'Pack Opening' in state:
            print(f'\nTurn {turn}: PACK OPENING')
            do_action(s, {'action': 'skip'})

        else:
            first = [l.strip() for l in state.split('\n')[:3] if l.strip()]
            print(f'\nTurn {turn}: ??? {first}')

    s.close()
    print('\n=== DONE ===')

if __name__ == '__main__':
    main()
