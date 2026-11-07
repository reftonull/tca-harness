#!/usr/bin/env python3
"""Turn raw recordings (fixtures/raw, gitignored) into the committed cassettes (fixtures/criticalmaps).

Recordings come from the production services with the read-only live guard on (see README). They hold
real people's data, so nothing is committed as recorded:

- Riders: device ids and positions are replaced (synthetic riders around Berlin); the count is kept.
- Mastodon: accounts, text, links, avatars and media are replaced; ids, order and pagination are kept,
  so `max_id` paging still matches. Avatars and media are dropped so the UI rung fetches no images.
- Next rides (criticalmass.in, public event listings): kept.
- Every timestamp is moved by the same offset, so the recording time lands on the harness's fixed
  date (HarnessDeterministic.startDate, 2026-01-01T00:00:00Z). Upcoming rides stay upcoming and
  messages stay older than "now" in deterministic runs.

Synthetic cassettes (marked with "note") fill what a read-only recording can't: chat messages (the
public chat was empty), the end of the Mastodon feed, and acknowledgements for the writes that replay
answers instead of the server.
"""
import email.utils
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / 'raw', HERE / 'criticalmaps'
START = 1_767_225_600  # HarnessDeterministic.startDate


def load(name):
    return json.loads((RAW / name).read_text())


def recorded_at(cassette):
    return int(email.utils.parsedate_to_datetime(cassette['response']['headers']['Date']).timestamp())


def iso(seconds):
    import datetime
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def parse_iso(text):
    import datetime
    return int(datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp())


def write(name, cassette, note=None):
    cassette['response']['headers'] = {'Content-Type': 'application/json'}
    if note:
        cassette = {'note': note, **cassette}
    (OUT / name).write_text(json.dumps(cassette, indent=2, sort_keys=False, ensure_ascii=False) + '\n')


def scrub(value):
    """Blanks any media or avatar URL left in nested objects."""
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, str) and ('files.mastodon' in item or 'cdn.masto' in item):
                value[key] = ''
            else:
                scrub(item)
    elif isinstance(value, list):
        for item in value:
            scrub(item)


def cassette(method, url, body, request_body=None, status=200):
    return {'request': {'method': method, 'url': url, 'body': request_body},
            'response': {'status': status, 'headers': {}, 'body': body}}


shutil.rmtree(OUT, ignore_errors=True)
OUT.mkdir()

# Riders: keep the count, replace who and where. Positions on a small spiral around Alexanderplatz.
c = load('GET__locations_1.json')
shift = START - recorded_at(c)
riders = []
for i, rider in enumerate(c['response']['body']):
    riders.append({'device': f'harness-rider-{i + 1:02d}', 'latitude': 52_521_900 + (i % 4 - 2) * 900 + i * 37,
                   'longitude': 13_413_200 + (i // 4 - 1) * 1400 - i * 23, 'timestamp': rider['timestamp'] + shift})
c['response']['body'] = riders
write('GET__locations_1.json', c)

# Next rides: public listings, kept as recorded. Not rebased: the request already asks for the month
# of the harness's fixed date (`month=1&year=2026`), so these are January 2026 rides.
write('GET__api_ride_1.json', load('GET__api_ride_1.json'))

# Mastodon: two recorded pages, anonymized; then a synthetic empty page that ends the feed.
names = {}
last_id = None
for n in (1, 2):
    c = load(f'GET__api_v1_timelines_tag_CriticalMass_{n}.json')
    shift = START - recorded_at(c)
    for toot in c['response']['body']:
        handle = names.setdefault(toot['account']['id'], f'rider{len(names) + 1}')
        account = toot['account']
        account.update({'acct': handle, 'username': handle, 'display_name': f'Rider {handle[5:]}',
                        'url': f'https://mastodon.social/@{handle}', 'avatar': '', 'avatar_static': '',
                        'header': '', 'header_static': '', 'note': '', 'fields': [], 'emojis': []})
        for key in ('avatar_description', 'header_description'):
            if key in account:
                account[key] = ''
        account.pop('moved', None)
        toot.update({'content': f'<p>Toot {toot["id"][-4:]} about the next #CriticalMass ride.</p>',
                     'url': f'https://mastodon.social/@{handle}/{toot["id"]}',
                     'uri': f'https://mastodon.social/users/{handle}/statuses/{toot["id"]}',
                     'media_attachments': [], 'mentions': [], 'emojis': [], 'card': None, 'poll': None,
                     'reblog': None, 'spoiler_text': '', 'in_reply_to_id': None, 'in_reply_to_account_id': None,
                     'application': None, 'tags': [{'name': 'criticalmass', 'url': 'https://mastodon.social/tags/criticalmass'}]})
        toot['created_at'] = iso(parse_iso(toot['created_at']) + shift)
        if toot.get('edited_at'):
            toot['edited_at'] = toot['created_at']
        for key in ('created_at', 'last_status_at'):
            if isinstance(account.get(key), str) and 'T' in account[key]:
                account[key] = iso(parse_iso(account[key]) + shift)
        toot.pop('quote', None)  # quoted posts embed another person's post and account
        scrub(toot)
        last_id = toot['id']
    write(f'GET__api_v1_timelines_tag_CriticalMass_{n}.json', c)
write('GET__api_v1_timelines_tag_CriticalMass_3.json',
      cassette('GET', f'https://mastodon.social/api/v1/timelines/tag/CriticalMass?max_id={last_id}&limit=40', []),
      note='Synthetic: the page after the second recorded page is empty, which ends the feed.')

# Chat: the public chat was empty when recorded. Three synthetic messages, older than "now".
messages = [{'identifier': f'harness-message-{i}', 'device': f'harness-rider-0{i}',
             'message': text, 'timestamp': START - (4 - i) * 300}
            for i, text in enumerate(['Meeting at Alexanderplatz at 19:00', 'Bring lights!', 'See you there'], start=1)]
# Replay serves equal recordings in order, repeating the last: the third fetch (launch, opening the
# chat, then the next poll) brings one new message, like a live chat.
for n in (1, 2):
    write(f'GET__messages_{n}.json', cassette('GET', 'https://api-gw.criticalmaps.net/messages', messages),
          note='Synthetic: the recorded chat was empty. Shape from SharedModels.ChatMessage.')
newer = messages + [{'identifier': 'harness-message-4', 'device': 'harness-rider-04',
                     'message': 'Running 5 minutes late', 'timestamp': START + 30}]
write('GET__messages_3.json', cassette('GET', 'https://api-gw.criticalmaps.net/messages', newer),
      note='Synthetic: from the third fetch on, one message newer than the last read.')

# Writes: never sent to the server; replay acknowledges them.
write('POST__messages_1.json', cassette('POST', 'https://api-gw.criticalmaps.net/messages', {'status': 'ok'}),
      note='Synthetic: chat posts are refused by the live guard and never recorded.')
write('PUT__locations_1.json', cassette('PUT', 'https://api-cdn.criticalmaps.net/locations', {'status': 'ok'}),
      note='Synthetic: location updates are refused by the live guard and never recorded.')
print('Wrote', len(list(OUT.iterdir())), 'cassettes to', OUT)
