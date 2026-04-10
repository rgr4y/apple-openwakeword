VENV   := .venv
PYTHON := $(VENV)/bin/python

.PHONY: venv start test-tts clean

venv:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -r requirements.txt

start: venv
	$(PYTHON) wyoming-say.py

test-tts: venv
	@echo "Testing macOS say renders audio..."
	@/usr/bin/say -o /tmp/wyoming-say-test.wav --data-format=LEI16@16000 "Wyoming TTS test"
	@python3 -c "import wave; w=wave.open('/tmp/wyoming-say-test.wav'); print(f'OK: {w.getnframes()} frames, {w.getframerate()}Hz, {w.getsampwidth()}B, {w.getnchannels()}ch'); w.close()"
	@rm -f /tmp/wyoming-say-test.wav
	@echo "Checking wyoming import..."
	@$(PYTHON) -c "from wyoming.tts import Synthesize; print('OK: wyoming imported')"

clean:
	rm -rf $(VENV) __pycache__ *.log
