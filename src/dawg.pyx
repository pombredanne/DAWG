from __future__ import unicode_literals
from libcpp.string cimport string
from iostream cimport stringstream, istream, ostream

cimport _dawg
from _dawg_builder cimport DawgBuilder
from _dictionary cimport Dictionary
from _guide cimport Guide
from _completer cimport Completer
from _base_types cimport BaseType, SizeType
cimport _guide_builder
cimport _dictionary_builder

import operator
import collections
import struct

cdef class DAWG:
    """
    Base DAWG wrapper.
    """
    cdef Dictionary dct
    cdef _dawg.Dawg dawg

    def __dealloc__(self):
        self.dct.Clear()
        self.dawg.Clear()

    def __init__(self, arg=None):
        if arg is None:
            arg = []
        self._build_from_keys_iterable(sorted(list(arg)))


    cdef _build_from_keys_iterable(self, iterable):
        cdef DawgBuilder dawg_builder

        cdef bytes b_key
        for key in iterable:
            if isinstance(key, unicode):
                b_key = key.encode('utf8')
            else:
                b_key = key
            dawg_builder.Insert(b_key)

        dawg_builder.Finish(&self.dawg)
        _dictionary_builder.Build(self.dawg, &(self.dct))

    def __contains__(self, key):
        if isinstance(key, unicode):
            return self.has_key(key)
        return self.b_has_key(key)

    cpdef bint has_key(self, unicode key) except -1:
        cdef bytes b_key = key.encode('utf8')
        return self.b_has_key(b_key)

    cpdef bint b_has_key(self, bytes key) except -1:
        return self.dct.Contains(key)

    cpdef bytes tobytes(self) except +:
        """
        Returns raw DAWG content as bytes.
        """
        cdef stringstream stream
        self.dct.Write(<ostream *> &stream)
        cdef bytes res = stream.str()
        return res

    cpdef frombytes(self, bytes data) except +:
        """
        Loads DAWG from bytes ``data``.
        """
        cdef stringstream* stream = new stringstream(data)
        try:
            self.dct.Read(<istream *> stream)
        finally:
            del stream
        return self

    def read(self, f):
        """
        Loads DAWG from a file-like object.

        FIXME: this method should'n read the whole stream.
        """
        self.frombytes(f.read())

    def write(self, f):
        """
        Writes DAWG to a file-like object.
        """
        f.write(self.tobytes())

    def load(self, path):
        """
        Loads DAWG from a file.
        """
        with open(path, 'r') as f:
            self.read(f)

    def save(self, path):
        """
        Saves DAWG to a file.
        """
        with open(path, 'w') as f:
            self.write(f)

    # pickling support
    def __reduce__(self):
        return self.__class__, tuple(), self.tobytes()

    def __setstate__(self, state):
        self.frombytes(state)

    # half-internal methods
    def _size(self):
        return self.dct.size()

    def _total_size(self):
        return self.dct.total_size()

    def _file_size(self):
        return self.dct.file_size()


cdef class CompletionDAWG(DAWG):
    """
    DAWG with key completion support.
    """
    cdef Guide guide

    def __init__(self, arg=None):
        super(CompletionDAWG, self).__init__(arg)
        if not _guide_builder.Build(self.dawg, self.dct, &self.guide):
            raise Exception("Error building completion information")

    def __dealloc__(self):
        self.guide.Clear()

    cpdef list keys(self, unicode prefix=""):
        cdef bytes b_prefix = prefix.encode('utf8')
        cdef bytes key
        cdef BaseType index = self.dct.root()
        cdef list res = []

        if not self.dct.Follow(b_prefix, &index):
            return res

        cdef Completer* completer = new Completer(self.dct, self.guide)
        try:
            completer.Start(index, b_prefix)
            while completer.Next():
                key = completer.key()
                res.append(key.decode('utf8'))

        finally:
            del completer

        return res

    cpdef bytes tobytes(self) except +:
        """
        Returns raw DAWG content as bytes.
        """
        cdef stringstream stream
        self.dct.Write(<ostream *> &stream)
        self.guide.Write(<ostream *> &stream)
        cdef bytes res = stream.str()
        return res

    cpdef frombytes(self, bytes data) except +:
        """
        Loads DAWG from bytes ``data``.
        """
        cdef stringstream* stream = new stringstream(data)
        try:
            self.dct.Read(<istream *> stream)
            self.guide.Read(<istream *> stream)
        finally:
            del stream
        return self


# This symbol is not allowed in utf8 so it is safe to use
# as a separator between utf8-encoded string and binary payload.
DEF PAYLOAD_SEPARATOR = b'\xff'

cdef class PayloadDAWG(CompletionDAWG):
    """
    DAWG that is able to transparently store extra binary payload in keys;
    there may be several payloads for the same key.

    In other words, this class implements read-only DAWG-based
    {unicode -> list of bytes objects} mapping.
    """

    def __init__(self, arg=None):
        """
        ``arg`` must be an iterable of tuples (unicode_key, bytes_payload).
        """
        if arg is None:
            arg = []

        keys = (self._raw_key(d[0], d[1]) for d in arg)

        super(PayloadDAWG, self).__init__(keys)


    cpdef bytes _raw_key(self, unicode key, bytes payload):
        return key.encode('utf8') + PAYLOAD_SEPARATOR + payload

    cpdef bint b_has_key(self, bytes key) except -1:
        cdef BaseType index
        return self._follow_key(key, &index)

    def __getitem__(self, key):
        cdef list res

        if isinstance(key, unicode):
            res = self.get_value(key)
        else:
            res = self.b_get_value(key)

        if not res:
            raise KeyError(key)
        return res

    cdef bint _follow_key(self, bytes key, BaseType* index):
        index[0] = self.dct.root()
        if not self.dct.Follow(key, len(key), index):
            return False
        return self.dct.Follow(PAYLOAD_SEPARATOR, index)


    cpdef list get_value(self, unicode key):
        cdef bytes b_key = key.encode('utf8')
        return self.b_get_value(b_key)

    cpdef list b_get_value(self, bytes key):
        cdef BaseType index
        cdef list res = []
        cdef bytes payload

        if not self._follow_key(key, &index):
            return res

        cdef Completer* completer = new Completer(self.dct, self.guide)
        try:
            completer.Start(index)
            while completer.Next():
                payload = completer.key()[:completer.length()]
                res.append(payload)
        finally:
            del completer

        return res

    cpdef list items(self, unicode prefix=""):
        cdef bytes b_prefix = prefix.encode('utf8')
        cdef bytes key, raw_key, value
        cdef list res = []

        cdef BaseType index = self.dct.root()
        if not self.dct.Follow(b_prefix, &index):
            return res

        cdef Completer* completer = new Completer(self.dct, self.guide)
        try:
            completer.Start(index, b_prefix)
            while completer.Next():
                raw_key = completer.key()[:completer.length()]
                key, value = raw_key.split(PAYLOAD_SEPARATOR, 1)
                res.append(
                    (key.decode('utf8'), value)
                )

        finally:
            del completer

        return res

    cpdef list keys(self, unicode prefix=""):
        keys, values = zip(*self.items(prefix))
        return keys


cdef class StructuredDAWG(PayloadDAWG):
    """
    DAWG that is able to transparently store binary payload in keys;
    there may be several payloads for the same key.

    The payload format must be defined at creation time using ``fmt``
    constructor argument; it has the same meaning as ``fmt`` argument
    for functions from ``struct`` module; take a look at
    http://docs.python.org/library/struct.html#format-strings for the
    specification.

    In other words, this class implements read-only DAWG-based
    {unicode -> list of tuples} mapping where all tuples are of the
    same structure an may be packed with the same format string.
    """
    cdef _struct

    def __init__(self, fmt, arg=None):
        """
        ``arg`` must be an iterable of tuples (unicode_key, data_tuple).
        data tuples will be converted to bytes with
        ``struct.pack(fmt, *data_tuple)``.

        Take a look at
        http://docs.python.org/library/struct.html#format-strings for the
        format string specification.
        """
        self._struct = struct.Struct(str(fmt))

        if arg is None:
            arg = []

        keys = ((d[0], self._struct.pack(*d[1])) for d in arg)
        super(StructuredDAWG, self).__init__(keys)


    cpdef list b_get_value(self, bytes key):
        cdef list values = PayloadDAWG.b_get_value(self, key)
        return [self._struct.unpack(val) for val in values]


    cpdef list items(self, unicode prefix=""):
        cdef list items = super(StructuredDAWG, self).items(prefix)
        return [(key, self._struct.unpack(val)) for (key, val) in items]



cdef class IntDict(DAWG):
    """
    Dict-like class based on DAWG.
    It can store integer values for unicode keys.
    """
    def __init__(self, arg=None):
        if arg is None:
            arg = []

        if isinstance(arg, collections.Mapping):
            iterable = ((key, arg[key]) for key in arg)
        else:
            iterable = arg

        iterable = sorted(iterable, key=operator.itemgetter(0))
        self._build_from_key_value_iterable(iterable)


    cpdef _build_from_key_value_iterable(self, iterable):
        cdef DawgBuilder dawg_builder

        cdef bytes b_key
        for key, value in iterable:
            b_key = key.encode('utf8')
            dawg_builder.Insert(b_key, value)

        cdef _dawg.Dawg dawg
        dawg_builder.Finish(&dawg)
        _dictionary_builder.Build(dawg, &(self.dct))


    def __getitem__(self, key):
        cdef int res

        if isinstance(key, unicode):
            res = self.get_value(key)
        else:
            res = self.b_get_value(key)

        if res == -1:
            raise KeyError(key)
        return res


    cpdef int get_value(self, unicode key):
        cdef bytes b_key = key.encode('utf8')
        return self.dct.Find(b_key)

    cpdef int b_get_value(self, bytes key):
        return self.dct.Find(key)