"""Extract the pinned Apache-2.0 ESPCN x2 GraphDef without TensorFlow.

Usage: python tools/import_espcn_model.py path/to/ESPCN_x2.pb
See native/super_resolution/MODEL.md for provenance and validation.
"""
import hashlib
import pathlib
import struct
import sys

SHA256 = '59f77351e1d7c0057bf6fe088b4a8a07e42c468c8c8aebb674a6b4ea1823221d'


def fields(data):
    def varint(offset):
        value = shift = 0
        while True:
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
            shift += 7

    offset = 0
    while offset < len(data):
        tag, offset = varint(offset)
        wire = tag & 7
        if wire == 0:
            value, offset = varint(offset)
        elif wire == 2:
            size, offset = varint(offset)
            value = data[offset:offset + size]
            offset += size
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError(f'Unsupported protobuf wire type {wire}')
        yield tag >> 3, value


def extract(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Model checksum differs from the reviewed graph')
    tensors = {}
    for tag, node in fields(data):
        if tag != 1:
            continue
        entries = list(fields(node))
        head = dict(entries)
        if head[2] != b'Const':
            continue
        for key, attribute in entries:
            if key != 5:
                continue
            attr = dict(fields(attribute))
            if attr[1] != b'value':
                continue
            tensor = dict(fields(dict(fields(attr[2]))[8]))
            if tensor[1] != 1:  # DT_FLOAT
                continue
            shape = [dict(fields(dim))[1] for k, dim in fields(tensor[2]) if k == 2]
            content = tensor[4]
            tensors[head[1].decode()] = (shape, struct.unpack('<%df' % (len(content) // 4), content))
    return tensors


def main():
    tensors = extract(pathlib.Path(sys.argv[1]).read_bytes())
    shapes = {'f1': [5, 5, 1, 64], 'b1': [64], 'f2': [3, 3, 64, 32],
              'b2': [32], 'f3': [3, 3, 32, 4], 'b3': [4]}
    output = ['// Generated from TF-ESPCN; Apache-2.0. See MODEL.md and LICENSE.',
              '#pragma once', 'namespace espcn {']
    for name, shape in shapes.items():
        dimensions, values = tensors[name]
        if dimensions != shape:
            raise ValueError(f'Unexpected {name} shape: {dimensions}')
        literals = []
        for value in values:
            text = format(value, '.9g')
            if '.' not in text and 'e' not in text:
                text += '.0'
            literals.append(text + 'f')
        output.append(f'alignas(32) static const float {name}[] = {{')
        output += ['  ' + ', '.join(literals[i:i + 8]) + ',' for i in range(0, len(literals), 8)]
        output.append('};')
    output.append('} // namespace espcn')
    target = pathlib.Path(__file__).resolve().parents[1] / 'native/super_resolution/espcn_weights.h'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(output) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
