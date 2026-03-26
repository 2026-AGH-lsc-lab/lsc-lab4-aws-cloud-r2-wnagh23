#!/usr/bin/env python3
"""Generate a fixed query vector for reproducible load testing."""
import json
import numpy as np

np.random.seed(42)
query = np.random.randn(128).tolist()
print(json.dumps({"query": query}))
