"""Export NVIDIA TitaNet-Large (waveform -> 192-d embedding) to Core ML.

Input: audio [1, WINDOW] float32 16 kHz mono, zero-padded; length [1] int32 valid samples.
Output: embedding [1, 192] (un-normalized, as NeMo's get_embedding returns).

Usage: python export_titanet_coreml.py [WINDOW] [OUT]
Precision is FP32, which is what the app ships and was calibrated on: the
spectrogram front end overflows in FP16 (cosine ~0.19 against NeMo). Set
TITANET_FP16=1 only to experiment; the parity gate below rejects it as is.
The package is written only after Core ML output matches NeMo.
"""
import glob, os, sys
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct
from nemo.collections.asr.models import EncDecSpeakerLabelModel

WINDOW = int(sys.argv[1]) if len(sys.argv) > 1 else 160000  # 10 s
OUT = sys.argv[2] if len(sys.argv) > 2 else "TitaNetLarge.mlpackage"

nemo_path = glob.glob(os.path.expanduser(
    "~/.cache/huggingface/hub/models--nvidia--speakerverification_en_titanet_large/snapshots/*/*.nemo"))[0]
model = EncDecSpeakerLabelModel.restore_from(nemo_path, map_location="cpu")
model.eval()
model.preprocessor.featurizer.dither = 0.0
model.preprocessor.featurizer.pad_to = 0


class STFTMel(nn.Module):
    """NeMo FilterbankFeatures re-expressed with conv1d DFT (Core ML friendly)."""

    def __init__(self, fb: "FilterbankFeatures"):
        super().__init__()
        self.n_fft = fb.n_fft
        self.hop = fb.hop_length
        win = fb.window.detach().float()  # win_length
        wl = win.numel()
        pad_l = (self.n_fft - wl) // 2
        full_win = torch.zeros(self.n_fft)
        full_win[pad_l:pad_l + wl] = win
        n = torch.arange(self.n_fft).float()
        k = torch.arange(self.n_fft // 2 + 1).float()
        ang = 2 * np.pi * k[:, None] * n[None, :] / self.n_fft
        self.register_buffer("cos_k", (torch.cos(ang) * full_win)[:, None, :])
        self.register_buffer("sin_k", (-torch.sin(ang) * full_win)[:, None, :])
        self.register_buffer("fb", fb.fb.detach().float()[0])  # [80, 257]
        self.preemph = fb.preemph
        self.guard = fb.log_zero_guard_value
        if callable(self.guard):
            self.guard = float(self.guard(torch.zeros(1)))
        self.guard = float(self.guard)

    def forward(self, x, length):
        # x [1, N], length [1] (float samples)
        n = x.shape[1]
        sidx = torch.arange(n, device=x.device).float()[None, :]
        smask = (sidx < length[:, None]).float()
        x = x * smask
        x = torch.cat([x[:, :1], x[:, 1:] - self.preemph * x[:, :-1]], dim=1)
        x = x * smask  # NeMo masks after pre-emphasis too
        pad = self.n_fft // 2
        x = nn.functional.pad(x[:, None, :], (pad, pad))  # center=True, constant
        re = nn.functional.conv1d(x, self.cos_k, stride=self.hop)
        im = nn.functional.conv1d(x, self.sin_k, stride=self.hop)
        power = re * re + im * im  # [1, 257, T]
        mel = torch.matmul(self.fb, power[0])[None]  # [1, 80, T]
        mel = torch.log(mel + self.guard)
        t = mel.shape[2]
        flen = torch.floor(length / self.hop) + 1
        fidx = torch.arange(t, device=x.device).float()[None, :]
        fmask = (fidx < flen[:, None]).float()[:, None, :]  # [1,1,T]
        cnt = flen[:, None, None]
        mean = (mel * fmask).sum(2, keepdim=True) / cnt
        var = (((mel - mean) * fmask) ** 2).sum(2, keepdim=True) / (cnt - 1)
        std = torch.sqrt(var) + 1e-5
        mel = (mel - mean) / std
        mel = mel * fmask
        return mel, flen


class Export(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.pre = STFTMel(m.preprocessor.featurizer)
        self.enc = m.encoder
        self.dec = m.decoder

    def forward(self, audio, length):
        lf = length.float()
        feats, flen = self.pre(audio, lf)
        enc, elen = self.enc(audio_signal=feats, length=flen.long())
        _, emb = self.dec(encoder_output=enc, length=elen)
        return emb


if __name__ == "__main__":
    exp = Export(model).eval()
    # Sanity vs NeMo on random speech-like noise
    torch.manual_seed(0)
    a = torch.randn(1, WINDOW) * 0.05
    L = torch.tensor([WINDOW * 3 // 5], dtype=torch.int32)
    with torch.no_grad():
        ref = model.forward(input_signal=a[:, : L.item()], input_signal_length=L.long())[1]
        mine = exp(a, L)
    print("torch export vs nemo cos:", float(nn.functional.cosine_similarity(ref, mine)))

    traced = torch.jit.trace(exp, (a, L))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, WINDOW), dtype=np.float32),
                ct.TensorType(name="length", shape=(1,), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16 if os.environ.get("TITANET_FP16") == "1" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "NVIDIA TitaNet-Large speaker embedding (192-d), waveform input, 16 kHz"
    mlmodel.author = "NVIDIA (CC-BY-4.0); Core ML export for MacParakeet"
    out = mlmodel.predict({"audio": a.numpy(), "length": L.numpy()})["embedding"]
    cos = float(nn.functional.cosine_similarity(ref, torch.tensor(out)))
    print("coreml vs nemo cos:", cos)
    # Noise input sits just below real speech (>= 0.9993 on 1.5-10 s clips);
    # a broken front end or FP16 overflow lands far below this.
    if cos < 0.998:
        raise SystemExit(f"parity check failed (cosine {cos:.4f} < 0.998); not writing {OUT}")
    mlmodel.save(OUT)
    print("saved", OUT)
