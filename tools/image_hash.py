# -*- coding: utf-8 -*-
"""
图片哈希工具（离线导入 / 去重校验共用）

pHash 64bit 参数（与 PROJECT.md 第 4 节口径一致）：
  灰度 → 32×32（LANCZOS）→ 正交 DCT-II → 取左上 8×8 低频 → 全 64 个系数取中位数二值化
  汉明距离 ≤6 判为同图

不依赖 scipy：用 numpy 显式构造正交 DCT-II 矩阵（等价 imagehash.phash 的 DCT 部分）。
"""
import hashlib

import numpy as np
from PIL import Image

HASH_SIZE = 8
IMG_SIZE = HASH_SIZE * 4
DEDUP_THRESHOLD = 6


def _dct_matrix(n: int) -> np.ndarray:
    """正交 DCT-II 变换矩阵：x = D @ block @ D.T"""
    k = np.arange(n).reshape(-1, 1)
    x = (np.arange(n) * 2 + 1).reshape(1, -1)
    m = np.cos(np.pi * k * x / (2.0 * n)) * np.sqrt(2.0 / n)
    m[0, :] = np.sqrt(1.0 / n)
    return m


_DCT = _dct_matrix(IMG_SIZE)


def phash64(path: str) -> str:
    """返回 16 位十六进制字符串（64bit pHash）"""
    with Image.open(path) as im:
        gray = im.convert('L').resize((IMG_SIZE, IMG_SIZE), Image.LANCZOS)
        block = np.asarray(gray, dtype=np.float64)
    coeff = _DCT @ block @ _DCT.T
    low = coeff[:HASH_SIZE, :HASH_SIZE].flatten()
    median = np.median(low)
    bits = (low > median).astype(np.uint8)
    return np.packbits(bits).tobytes().hex()


def hamming(a: str, b: str) -> int:
    """64bit 十六进制哈希的汉明距离"""
    return bin(int(a, 16) ^ int(b, 16)).count('1')


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as fp:
        for chunk in iter(lambda: fp.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def image_size(path: str):
    with Image.open(path) as im:
        return im.size


def aspect_ok(width: int, height: int) -> bool:
    """9:16 (0.5625) ~ 9:21 (0.4286)，竖图（宽/高）"""
    short_edge = min(width, height)
    long_edge = max(width, height)
    return short_edge >= 1080 and (9.0 / 21.0) <= (short_edge / float(long_edge)) <= (9.0 / 16.0)


def ratio(width: int, height: int) -> float:
    return min(width, height) / float(max(width, height))
