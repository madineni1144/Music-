# MADINENI LYRICS V1
"""Read existing MP3 ID3 lyrics without changing the audio file. Mutagen is optional."""
import json
import sys

def read(path):
    try:
        from mutagen.id3 import ID3
        tags = ID3(path)
    except Exception:
        return {}
    result = {}
    plain = tags.getall('USLT')
    if plain:
        result['plainLyrics'] = str(plain[0].text)[:262144]
    synced = [f for f in tags.getall('SYLT') if f.format == 2 and f.type == 1]
    if synced:
        pieces = []
        for text, milliseconds in synced[0].text:
            # ID3 SYLT can be word-timed. Convert each event to a timed line.
            seconds = max(0, milliseconds / 1000)
            minutes = int(seconds // 60)
            words = str(text).replace('\r', '').replace('\n', ' ')
            pieces.append(f'[{minutes:02}:{seconds % 60:05.2f}]{words}')
        result['syncedLyrics'] = '\n'.join(pieces)[:262144]
    return result

if __name__ == '__main__':
    try:
        result = read(sys.argv[1])
    except Exception:
        result = {}
    print(json.dumps(result, ensure_ascii=False))
