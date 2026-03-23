import random
import numpy as np


def generate_fantasy_name():
    prefixes = ['Aether', 'Bane', 'Celest', 'Dusk', 'Ember', 'Frost', 'Gale', 'Haven', 'Ivory', 'Jade', 'Kairos', 'Lore', 'Myst', 'Nebula', 'Orion', 'Petal', 'Quasar', 'Raven', 'Seren', 'Thorn', 'Umbra', 'Vale', 'Wraith', 'Xi', 'Yara', 'Zephyr', 'Solaris', 'Sylvan', 'Eclipse', 'Azure', 'Draco', 'Typhoon']
    suffixes = ['blade', 'crest', 'dream', 'flame', 'gloom', 'heart', 'illusion', 'jewel', 'knight', 'light', 'moon', 'noble', 'oracle', 'phantom', 'quill', 'radiance', 'shadow', 'song', 'tempest', 'veil', 'whisper', 'xenon', 'yonder', 'zenith', 'Aegis', 'Enigma', 'Harmony', 'Mirage', 'Nimbus', 'Rhapsody', 'Spectre', 'Tranquil', 'Vortex', 'Zephyr', 'Avalanche', 'Cinder', 'Scepter', 'Twilight', 'Galaxy']
    rand_num    =  str(np.random.randint(low=11, high=99))
    return random.choice(prefixes).lower() + random.choice(suffixes).lower()+''+rand_num

def experiment_name():
    run_name_str=generate_fantasy_name()
    return run_name_str
