"""Official SDK clients -> real KeyDock proxy -> loopback fixture, never a cloud API."""
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ENV = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
ENV.update(NO_PROXY="*", no_proxy="*", PYTHONDONTWRITEBYTECODE="1")

def clients(config):
    from openai import OpenAI, AsyncOpenAI
    from anthropic import Anthropic, AsyncAnthropic
    o = config["compatible"]; a = config["anthropic"]
    options = dict(timeout=4.0, max_retries=0)
    for vendor in ("qwen", "doubao", "kimi", "deepseek", "baichuan", "relay"):
        with OpenAI(**config[vendor], **options) as client:
            yield vendor + ".chat-via-proxy", lambda: client.chat.completions.create(model="fixture-"+vendor, messages=[{"role":"user","content":"test"}]).choices[0].message.content == "ACK"
            def stream():
                with client.chat.completions.create(model="fixture-"+vendor, messages=[{"role":"user","content":"test"}], stream=True, extra_headers={"X-Workspace":"client-must-not-override"}) as chunks:
                    return "".join(c.choices[0].delta.content or "" for c in chunks) == "ACK"
            yield vendor + ".stream-via-proxy", stream
    with OpenAI(**o, **options) as client:
        yield "OpenAI.chat", lambda: client.chat.completions.create(model="fixture-model", messages=[{"role":"user","content":"test"}]).choices[0].message.content == "ACK"
        def stream():
            with client.chat.completions.create(model="fixture-model", messages=[{"role":"user","content":"test"}], stream=True) as chunks:
                return "".join(c.choices[0].delta.content or "" for c in chunks) == "ACK"
        yield "OpenAI.stream", stream
        yield "OpenAI.models", lambda: next(iter(client.models.list())).id == "fixture-model"
        yield "OpenAI.responses", lambda: client.responses.create(model="fixture-model",input="test").output_text == "ACK"
        def responses_stream():
            with client.responses.stream(model="fixture-model",input="test") as stream:
                return stream.get_final_response().output_text == "ACK"
        yield "OpenAI.responses-stream", responses_stream
    with Anthropic(**a, **options) as client:
        yield "Anthropic.messages", lambda: client.messages.create(model="fixture-model",max_tokens=16,messages=[{"role":"user","content":"test"}]).content[0].text == "ACK"
        def stream():
            with client.messages.stream(model="fixture-model",max_tokens=16,messages=[{"role":"user","content":"test"}]) as events:
                return "".join(events.text_stream) == "ACK"
        yield "Anthropic.stream", stream
        yield "Anthropic.models", lambda: next(iter(client.models.list())).id == "fixture-model"
    from google import genai
    from google.genai import types
    g = config["gemini"]
    client = genai.Client(api_key=g["api_key"], http_options=types.HttpOptions(base_url=g["base_url"],api_version="v1beta",timeout=4000,retry_options=types.HttpRetryOptions(attempts=1)))
    try:
        yield "Gemini.generate", lambda: client.models.generate_content(model="fixture-model",contents="test").text == "ACK"
        yield "Gemini.stream", lambda: "".join(c.text or "" for c in client.models.generate_content_stream(model="fixture-model",contents="test")) == "ACK"
        yield "Gemini.models", lambda: next(iter(client.models.list())).name == "models/fixture-model"
    finally:
        client.close()
    async def async_calls():
        async with AsyncOpenAI(**o, **options) as client:
            reply = await client.chat.completions.create(model="fixture-model",messages=[{"role":"user","content":"test"}])
            assert reply.choices[0].message.content == "ACK"
            reply = await client.responses.create(model="fixture-model",input="test")
            assert reply.output_text == "ACK"
            async with client.responses.stream(model="fixture-model",input="test") as stream:
                assert (await stream.get_final_response()).output_text == "ACK"
        async with AsyncAnthropic(**a, **options) as client:
            reply = await client.messages.create(model="fixture-model",max_tokens=16,messages=[{"role":"user","content":"test"}])
            assert reply.content[0].text == "ACK"
    yield "SDK.async-clients", lambda: asyncio.run(async_calls()) is None

def main():
    print("VERSIONS", json.dumps({name:importlib.metadata.version(name) for name in ["openai","anthropic","google-genai"]}))
    fixture = subprocess.Popen([str(ROOT/".build/checks/KeyDockChecks"),"--sdk-fixture"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,env=ENV)
    try:
        selector=selectors.DefaultSelector(); selector.register(fixture.stdout,selectors.EVENT_READ)
        if not selector.select(timeout=6):
            raise RuntimeError("fixture failed to become ready")
        config=json.loads(fixture.stdout.readline())["accounts"]
        failures=[]; total=0
        for name,run in clients(config):
            total+=1
            try:
                assert run(), "unexpected SDK response"
                print("PASS",name,flush=True)
            except Exception as exc:
                failures.append(name)
                print("FAIL",name,type(exc).__name__,str(exc)[:250],flush=True)
        print(json.dumps({"scenarios":total,"failed":failures}),flush=True)
        return bool(failures)
    finally:
        fixture.terminate()
        try: fixture.wait(timeout=3)
        except subprocess.TimeoutExpired: fixture.kill();fixture.wait()

if __name__ == "__main__":
    # Explicit fake aliases are the only client credentials; omit inherited provider credentials.
    if "--isolated" not in sys.argv:
        result=subprocess.run([sys.executable,"-B",__file__,"--isolated"],env=ENV)
        raise SystemExit(result.returncode)
    raise SystemExit(main())
