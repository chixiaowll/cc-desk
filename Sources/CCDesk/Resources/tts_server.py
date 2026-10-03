#!/usr/bin/env python3
"""CC Desk 自然语音服务（Qwen3-TTS via mlx-audio）。

常驻 stdio 进程：加载模型一次、预热，然后从 stdin 读一行一个 JSON 请求，
往 stdout 写长度前缀的二进制帧。诊断只写 stderr。

请求：
  {"id": "u3.0", "text": "你好", "voice": "serena", "lang": "chinese"}   合成（按到达顺序排队）
  {"cancel": "u3.0"}                                  取消某个请求（正在合成的会在下一块音频前停下）
  {"cancel": "*"}                                     取消全部（打断 / barge-in）

帧：4 字节大端长度 N，随后 N 字节：
  kind(1 字节) | id 长度(1 字节) | id(UTF-8) | payload
  kind 0 = ready（payload：JSON 信息，id 为空）
  kind 1 = audio（payload：float32 小端 PCM，24 kHz 单声道）
  kind 2 = end（payload：JSON 统计，含 cancelled）
  kind 3 = error（payload：UTF-8 消息）

`--download <dir>`：把模型下载到 <dir>（安装时用），进度写 stderr，成功退出码 0。
"""

import json
import os
import struct
import sys
import threading
import time
import traceback
from collections import deque

REPO = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
SAMPLE_RATE = 24000
KIND_READY, KIND_AUDIO, KIND_END, KIND_ERROR = 0, 1, 2, 3
# 0.9（默认）偶尔会说乱；稍低更稳，仍保留自然的语调起伏。
TEMPERATURE = float(os.environ.get("CCDESK_TTS_TEMPERATURE", "0.7"))
STREAMING_INTERVAL = float(os.environ.get("CCDESK_TTS_INTERVAL", "0.5"))
MAX_TEXT = 600

# 帧只写到原来的 stdout（另存一个 fd）；fd 1 改指向 stderr，库里零散的 print 不会弄乱帧流。
_out = os.fdopen(os.dup(1), "wb")
os.dup2(2, 1)
sys.stdout = sys.stderr
_out_lock = threading.Lock()


def log(*args):
    print("[tts]", *args, file=sys.stderr, flush=True)


def write_frame(kind, rid, payload=b""):
    rid_bytes = (rid or "").encode("utf-8")[:255]
    body = bytes([kind, len(rid_bytes)]) + rid_bytes + payload
    with _out_lock:
        try:
            _out.write(struct.pack(">I", len(body)) + body)
            _out.flush()
        except (BrokenPipeError, OSError):
            # App 已经关掉管道：直接退出。
            os._exit(0)


class Job:
    __slots__ = ("rid", "text", "voice", "lang", "cancelled")

    def __init__(self, rid, text, voice, lang):
        self.rid, self.text, self.voice, self.lang = rid, text, voice, lang
        self.cancelled = False


class Queue:
    """请求队列：读线程放入 / 取消，合成线程取出。"""

    def __init__(self):
        self.cond = threading.Condition()
        self.jobs = deque()
        self.current = None
        self.closed = False

    def put(self, job):
        with self.cond:
            self.jobs.append(job)
            self.cond.notify()

    def cancel(self, rid):
        with self.cond:
            if rid == "*":
                dropped = list(self.jobs)
                self.jobs.clear()
                if self.current:
                    self.current.cancelled = True
            else:
                dropped = [j for j in self.jobs if j.rid == rid]
                self.jobs = deque(j for j in self.jobs if j.rid != rid)
                if self.current and self.current.rid == rid:
                    self.current.cancelled = True
        for job in dropped:
            write_frame(KIND_END, job.rid, json.dumps({"cancelled": True}).encode())

    def take(self):
        with self.cond:
            while not self.jobs and not self.closed:
                self.cond.wait()
            if not self.jobs:
                return None
            self.current = self.jobs.popleft()
            return self.current

    def done(self):
        with self.cond:
            self.current = None

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()


def reader(queue):
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
            if not isinstance(msg, dict):
                raise ValueError("request must be an object")
            if "cancel" in msg:
                queue.cancel(str(msg["cancel"]))
                continue
            rid = str(msg.get("id", ""))
            text = str(msg.get("text", "")).strip()[:MAX_TEXT]
            voice = str(msg.get("voice") or "serena")
            lang = str(msg.get("lang") or "chinese")
            if not rid:
                raise ValueError("missing id")
            if not text:
                write_frame(KIND_END, rid, json.dumps({"cancelled": False, "empty": True}).encode())
                continue
            queue.put(Job(rid, text, voice, lang))
        except Exception as e:  # 坏输入不能让服务挂掉
            log("bad request:", repr(line[:200]), e)
            write_frame(KIND_ERROR, "", f"bad request: {e}".encode())
    log("stdin closed, exiting")
    queue.close()


def synthesize(model, job, np, mx):
    started = time.time()
    first = None
    samples = 0
    # 固定种子：同一句话每次读法一致，也避免偶发的怪音。
    mx.random.seed(len(job.text) * 7919 + 17)
    for result in model.generate(text=job.text, voice=job.voice, lang_code=job.lang, temperature=TEMPERATURE,
                                 stream=True, streaming_interval=STREAMING_INTERVAL):
        if job.cancelled:
            break
        audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
        if audio.size == 0:
            continue
        if first is None:
            first = time.time() - started
        samples += audio.size
        write_frame(KIND_AUDIO, job.rid, audio.astype("<f4").tobytes())
        if job.cancelled:
            break
    elapsed = time.time() - started
    stats = {"cancelled": job.cancelled, "first_audio_s": round(first or 0, 3), "elapsed_s": round(elapsed, 3),
             "audio_s": round(samples / SAMPLE_RATE, 3)}
    log(f"{job.rid}: {stats} {job.text[:40]!r}")
    return stats


def serve(model_dir):
    t0 = time.time()
    import numpy as np
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model

    model = load_model(model_dir)
    loaded = time.time() - t0
    # 预热：第一次合成要编译 / 分配，放在 ready 之前做掉。
    for _ in model.generate(text="你好。", voice="serena", lang_code="chinese", temperature=TEMPERATURE):
        pass
    warm = time.time() - t0
    log(f"model loaded in {loaded:.2f}s, ready in {warm:.2f}s")
    write_frame(KIND_READY, "", json.dumps({"load_s": round(loaded, 2), "ready_s": round(warm, 2),
                                            "sample_rate": SAMPLE_RATE}).encode())

    queue = Queue()
    threading.Thread(target=reader, args=(queue,), daemon=True).start()
    while True:
        job = queue.take()
        if job is None:
            break
        try:
            if job.cancelled:
                stats = {"cancelled": True}
            else:
                stats = synthesize(model, job, np, mx)
            write_frame(KIND_END, job.rid, json.dumps(stats).encode())
        except Exception as e:
            log(f"synthesis failed for {job.rid}:", e)
            traceback.print_exc(file=sys.stderr)
            write_frame(KIND_ERROR, job.rid, str(e).encode())
        finally:
            queue.done()
            mx.clear_cache()


def download(target):
    from huggingface_hub import snapshot_download

    log(f"downloading {REPO} -> {target}")
    snapshot_download(REPO, local_dir=target)
    log("download finished")


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--download":
        download(args[1])
        return
    if len(args) != 1:
        log("usage: tts_server.py <model_dir> | --download <dir>")
        sys.exit(2)
    try:
        serve(args[0])
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        write_frame(KIND_ERROR, "", f"startup failed: {e}".encode())
        sys.exit(1)


if __name__ == "__main__":
    main()
