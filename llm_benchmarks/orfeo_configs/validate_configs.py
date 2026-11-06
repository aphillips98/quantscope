#!/usr/bin/env python3
from pathlib import Path
import yaml
root=Path(__file__).resolve().parent
models=yaml.safe_load((root/'models.yml').read_text())['models']
hardware=yaml.safe_load((root/'hardware_profiles.yml').read_text())['profiles']
for hw in ('a100','v100','h100'):
    c=yaml.safe_load((root/'campaigns'/f'{hw}.yml').read_text())
    assert c['hardware_profile']==hw
    assert hw in hardware
    assert all(m in models for m in c['models'])
    assert all('max_sample' not in b and 'max_samples' not in b for b in c['benchmarks'].values())
    assert f'/{hw.upper()}/' in c['profiling']['library_path']
    s=yaml.safe_load((root/f'slurm.{hw}.yml').read_text())
    for k in ('models','campaign','hardware'):
        assert s[k].startswith('orfeo_configs/'),(hw,k,s[k])
        assert (root/s[k].split('/',1)[1]).exists(),(hw,k,s[k])
for m in models.values():
    assert m['inference']['mode']=='chat'
    assert m['inference']['gpu_layers']==-1
print('PASS: YAML structure, model references, profile references, slurm paths and inference consistency')
