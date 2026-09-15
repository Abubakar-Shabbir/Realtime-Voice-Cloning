import json
import os
import sys

exp = sys.argv[1]
root = os.getcwd()
d = f"{root}/logs/{exp}"
gt, fea, f0, nsf = (f"{d}/0_gt_wavs", f"{d}/3_feature768", f"{d}/2a_f0", f"{d}/2b-f0nsf")


def stems(p):
    return {n.split(".")[0] for n in os.listdir(p)}


names = sorted(stems(gt) & stems(fea) & stems(f0) & stems(nsf))
if not names:
    sys.exit("no training items: preprocessing/feature extraction produced nothing")

lines = [f"{gt}/{n}.wav|{fea}/{n}.npy|{f0}/{n}.wav.npy|{nsf}/{n}.wav.npy|0" for n in names]
m = f"{root}/logs/mute"
lines += [f"{m}/0_gt_wavs/mute40k.wav|{m}/3_feature768/mute.npy|{m}/2a_f0/mute.wav.npy|{m}/2b-f0nsf/mute.wav.npy|0"] * 2
with open(f"{d}/filelist.txt", "w", encoding="utf8") as f:
    f.write("\n".join(lines))

# webui uses configs/v1/40k.json for every 40k model (no v2/40k.json upstream)
with open(f"{root}/configs/v1/40k.json", encoding="utf8") as f:
    cfg = json.load(f)
cfg.pop("speaker_info", None)
with open(f"{d}/config.json", "w", encoding="utf8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=4, sort_keys=True)
    f.write("\n")

print(f"items={len(names)} filelist={d}/filelist.txt config={d}/config.json")
