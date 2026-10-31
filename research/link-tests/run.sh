#!/bin/zsh
# Testes do protocolo remoto (sem iPhone): compila com o código partilhado da app e corre.
cd "${0:A:h}"; S=../../Shared; mkdir -p .build
swiftc -O -parse-as-library -o .build/linktests main.swift BenchLoad.swift $S/Link.swift $S/LinkCrypto.swift $S/AudioCodec.swift $S/MacSender.swift $S/FalaGroup.swift $S/Jarvis.swift $S/CallClient.swift $S/LiveScreenClient.swift 2>&1 | grep -E "^[^ ]*: error:" && { echo "FALHA: não compilou"; exit 1; }
.build/linktests ../stt-benchmark/audio/long_joana.wav
